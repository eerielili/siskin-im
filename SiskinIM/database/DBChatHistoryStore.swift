//
// DBChatHistoryStore.swift
//
// Siskin IM
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//


import Foundation
import TigaseSwift
import TigaseSwiftOMEMO

open class DBChatHistoryStore: Logger, EventHandler {
    
    public static let MESSAGE_NEW = Notification.Name("messengerMessageNew");
    public static let CHAT_ITEMS_UPDATED = Notification.Name("messengerChatUpdated");
    public static let MESSAGE_UPDATED = Notification.Name("messengerMessageUpdated");
    
    fileprivate static let CHAT_GET_ID_WITH_ACCOUNT_PARTICIPANT_AND_STANZA_ID = "SELECT id FROM chat_history WHERE account = :account AND jid = :jid AND stanza_id = :stanzaId";
    fileprivate static let CHAT_MSG_APPEND = "INSERT INTO chat_history (account, jid, author_jid, author_nickname, timestamp, item_type, data, stanza_id, state, encryption, fingerprint) VALUES (:account, :jid, :author_jid, :author_nickname, :timestamp, :item_type, :data, :stanza_id, :state, :encryption, :fingerprint)";
    fileprivate static let CHAT_MSGS_COUNT = "SELECT count(id) FROM chat_history WHERE account = :account AND jid = :jid";
    fileprivate static let CHAT_MSGS_COUNT_UNREAD_CHATS = "select count(1) FROM (SELECT account, jid FROM chat_history WHERE state in (\(State.incoming_unread.rawValue), \(State.incoming_error_unread.rawValue), \(State.outgoing_error_unread.rawValue)) GROUP BY account, jid) as x";
    fileprivate static let CHAT_MSGS_DELETE = "DELETE FROM chat_history WHERE account = :account AND jid = :jid";
    fileprivate static let CHAT_MSGS_GET = "SELECT id, author_jid, author_nickname, timestamp, item_type, data, state, preview, encryption, fingerprint FROM chat_history WHERE account = :account AND jid = :jid ORDER BY timestamp DESC LIMIT :limit OFFSET :offset"
    fileprivate static let CHAT_MSG_UPDATE_PREVIEW = "UPDATE chat_history SET preview = :preview WHERE id = :id";
    fileprivate static let CHAT_MSGS_MARK_AS_READ = "UPDATE chat_history SET state = case state when \(State.incoming_error_unread.rawValue) then \(State.incoming_error.rawValue) when \(State.outgoing_error_unread.rawValue) then \(State.outgoing_error.rawValue) else \(State.incoming.rawValue) end WHERE account = :account AND jid = :jid AND state in (\(State.incoming_unread.rawValue), \(State.incoming_error_unread.rawValue), \(State.outgoing_error_unread.rawValue))";
    fileprivate static let CHAT_MSG_CHANGE_STATE = "UPDATE chat_history SET state = :newState WHERE id = :id AND (:oldState IS NULL OR state = :oldState)";
    fileprivate static let MSG_ALREADY_ADDED = "SELECT count(id) FROM chat_history WHERE account = :account AND jid = :jid AND timestamp BETWEEN :ts_from AND :ts_to AND item_type = :item_type AND (:data IS NULL OR data = :data) AND (:stanza_id IS NULL OR (stanza_id IS NOT NULL AND stanza_id = :stanza_id)) AND (:author_jid is null OR author_jid = :author_jid) AND (:author_nickname is null OR author_nickname = :author_nickname)";
    
    public let dbConnection:DBConnection;
    
    fileprivate lazy var msgAppendStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSG_APPEND);
    fileprivate lazy var msgsCountStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSGS_COUNT);
    fileprivate lazy var msgsDeleteStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSGS_DELETE);
    fileprivate lazy var msgsCountUnreadChatsStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSGS_COUNT_UNREAD_CHATS);
    //private lazy var msgsGetStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSGS_GET);
    fileprivate lazy var msgGetIdWithAccountPariticipantAndStanzaIdStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_GET_ID_WITH_ACCOUNT_PARTICIPANT_AND_STANZA_ID);
    fileprivate lazy var msgsMarkAsReadStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSGS_MARK_AS_READ);
    fileprivate lazy var msgUpdatePreviewStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSG_UPDATE_PREVIEW);
    fileprivate lazy var msgUpdateStateStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSG_CHANGE_STATE);
    open lazy var msgAlreadyAddedStmt: DBStatement! = try? self.dbConnection.prepareStatement(DBChatHistoryStore.MSG_ALREADY_ADDED);
    fileprivate lazy var chatUpdateTimestamp: DBStatement! = try? self.dbConnection.prepareStatement("UPDATE chats SET timestamp = :timestamp WHERE account = :account AND jid = :jid AND timestamp < :timestamp");
    fileprivate lazy var listUnreadChatsStmt: DBStatement! = try? self.dbConnection.prepareStatement("SELECT DISTINCT account, jid FROM chat_history WHERE state in (\(State.incoming_unread.rawValue), \(State.incoming_error_unread.rawValue), \(State.outgoing_error_unread.rawValue))");
    fileprivate lazy var lastMessageTimestampForAccount: DBStatement! = try? self.dbConnection.prepareStatement("SELECT max(timestamp) AS timestamp FROM chat_history WHERE account = :account GROUP BY account");
    fileprivate lazy var getMessagePositionStmt: DBStatement! = try? self.dbConnection.prepareStatement("SELECT count(id) FROM chat_history WHERE account = :account AND jid = :jid AND id <> :msgId AND timestamp < (SELECT timestamp FROM chat_history WHERE id = :msgId)");
    fileprivate lazy var getMessagePositionStmtInverted: DBStatement! = try? self.dbConnection.prepareStatement("SELECT count(id) FROM chat_history WHERE account = :account AND jid = :jid AND id <> :msgId AND timestamp > (SELECT timestamp FROM chat_history WHERE id = :msgId)");
    fileprivate lazy var markMessageAsErrorStmt: DBStatement! = try? self.dbConnection.prepareStatement("UPDATE chat_history SET state = :state, error = :error WHERE id = :id");
    fileprivate lazy var getMessageErrorDetails: DBStatement! = try? self.dbConnection.prepareStatement("SELECT error FROM chat_history WHERE id = ?");
    
    fileprivate let dispatcher: QueueDispatcher;
    
    public init(dbConnection:DBConnection) {
        self.dispatcher = QueueDispatcher(label: "chat_history_store");
        self.dbConnection = dbConnection;
        super.init();
        NotificationCenter.default.addObserver(self, selector: #selector(DBChatHistoryStore.accountRemoved), name: NSNotification.Name(rawValue: "accountRemoved"), object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(DBChatHistoryStore.imageRemovedFromCache), name: ImageCache.DISK_CACHE_IMAGE_REMOVED, object: nil);
    }
    
    open func appendMessage(for sessionObject: SessionObject, message: Message, preview: String? = nil, carbonAction: MessageCarbonsModule.Action? = nil, fromArchive: Bool = false) {
        let account = sessionObject.userBareJid!;
        let (body, encryption, fingerprint) = prepareBody(message: message, forAccount:  account);
        // for now we support only messages with body
        guard body != nil else {
            return;
        }
        
        let incoming = message.from != nil && (carbonAction == nil
            ? message.from != ResourceBinderModule.getBindedJid(sessionObject)
            : message.from?.bareJid != sessionObject.userBareJid);
        
        let jid = incoming ? message.from?.bareJid : message.to?.bareJid
        let author = incoming ? message.from?.bareJid : account;
        let timestamp = message.delay?.stamp ?? Date();
        let state = calculateState(incoming: incoming, fromArchive: fromArchive, stanzaType: message.type);
        let itemType = ItemType.message;
        
        appendEntry(for: account, jid: jid!, state: state, authorJid: author, itemType: itemType, data: body!, timestamp: timestamp, id: message.id, encryption: encryption, encryptionFingerprint: fingerprint, fromArchive: fromArchive, carbonAction: carbonAction, nicknameInRoom: nil) { (msgId) in
        }
    }
    
    fileprivate func calculateState(incoming: Bool, fromArchive: Bool, stanzaType: StanzaType?) -> State {
        if incoming {
            if stanzaType == StanzaType.error {
                return fromArchive ? State.incoming_error : State.incoming_error_unread;
            } else {
                return fromArchive ? State.incoming : State.incoming_unread;
            }
        } else {
            if stanzaType == StanzaType.error {
                return fromArchive ? State.outgoing_error : State.outgoing_error_unread;
            }
            return State.outgoing;
        }
    }
    
//    fileprivate func markMessageAsError(message: Message) -> Bool {
//        guard let account = message.to?.bareJid, let jid = message.from?.bareJid, let id = message.id else {
//            print("got error message without a to or from or id!");
//            return false;
//        }
//
//        return processOutgoingError(for: account, with: jid, stanzaId: id, errorCondition: message.errorCondition, errorMessage: message.errorText);
//    }
    
    fileprivate func processOutgoingError(for account: BareJID, with jid: BareJID, stanzaId: String, errorCondition: ErrorCondition?, errorMessage: String?) -> Bool {

        guard let msgId = self.getMessageIdInt(account: account, jid: jid, stanzaId: stanzaId) else {
            return false;
        }

        let params: [String: Any?] = ["id": msgId, "state": State.outgoing_error_unread.rawValue, "error": errorMessage ?? errorCondition?.rawValue ?? "Unknown error"];
        if try! self.markMessageAsErrorStmt.update(params) > 0 {
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: DBChatHistoryStore.MESSAGE_UPDATED, object: self, userInfo: ["message-id": msgId, "state": State.outgoing_error_unread]);
            }
        }

        return true
    }
    
    fileprivate func prepareBody(message: Message, forAccount account: BareJID) -> (String?, MessageEncryption, String?) {
        var encryption: MessageEncryption = .none;
        var fingerprint: String? = nil;
        
        var encryptionErrorBody: String?;
        if let omemoModule: OMEMOModule = XmppService.instance.getClient(forJid: account)?.modulesManager.getModule(OMEMOModule.ID) {
            switch omemoModule.decode(message: message) {
            case .successMessage(let decodedMessage, let keyFingerprint):
                encryption = .decrypted;
                fingerprint = keyFingerprint
                break;
            case .successTransportKey(let key, let iv):
                print("got transport key with key and iv!");
            case .failure(let error):
                switch error {
                case .invalidMessage:
                    encryption = .notForThisDevice;
                    encryptionErrorBody = "Message was not encrypted for this device.";
                case .duplicateMessage:
                    if let from = message.from?.bareJid, checkItemAlreadyAdded(for: account, with: from, authorNickname: nil, itemType: .message, timestamp: message.delay?.stamp ?? Date(), stanzaId: message.getAttribute("id"), data: nil) {
                        return (nil, .none, nil);
                    }
                case .notEncrypted:
                    encryption = .none;
                default:
                    encryption = .decryptionFailed;
                    encryptionErrorBody = "Message decryption failed!";
                }
                break;
            }
        }
        
        guard let body = message.body ?? message.oob ?? encryptionErrorBody else {
            return (nil, encryption, nil);
        }
        guard (message.type ?? .chat) != .error else {
            guard let error = message.errorCondition else {
                return ("Error: Unknown error\n------\n\(body)", encryption, nil);
            }
            return ("Error: \(message.errorText ?? error.rawValue)\n------\n\(body)", encryption, nil);
        }
        return (body, encryption, fingerprint);
    }
    
    fileprivate func appendMucMessage(event e: MucModule.MessageReceivedEvent) {
        let account = e.sessionObject.userBareJid!;
        let (body, encryption, fingerprint) = prepareBody(message: e.message, forAccount: account);
        guard body != nil else {
            return;
        }
        
        let authorJid: BareJID? = e.nickname == nil ? nil : e.room.presences[e.nickname!]?.jid?.bareJid;
        let state = calculateState(incoming: e.nickname != e.room.nickname, fromArchive: false, stanzaType: e.message.type);
        
        appendEntry(for: account, jid: e.room.roomJid, state: state, authorJid: authorJid, authorNickname: e.nickname, data: body!, timestamp: e.timestamp, id: e.message.id, encryption: encryption, encryptionFingerprint: fingerprint, fromArchive: false, carbonAction: nil, nicknameInRoom: e.room.nickname) { (msgId) in
        }
    }
    
    func appendMessage(event e: MessageArchiveManagementModule.ArchivedMessageReceivedEvent) {
        
        let account = e.sessionObject.userBareJid!;
        let (body, encryption, fingerprint) = prepareBody(message: e.message, forAccount: account);
        // for now we support only messages with body
        guard body != nil else {
            return;
        }
        let message = e.message!;

        let state = calculateState(incoming: (message.from != nil && message.from!.bareJid != account), fromArchive: true, stanzaType: message.type);
        let jid = state.direction == .incoming ? message.from?.bareJid : message.to?.bareJid
        let author = state.direction == .incoming ? message.from?.bareJid : account;
        
        appendEntry(for: account, jid: jid!, state: state, authorJid: author, data: body!, timestamp: e.timestamp, id: message.id, encryption: encryption, encryptionFingerprint: fingerprint, fromArchive: true, carbonAction: nil, nicknameInRoom: nil) { (msgId) in
        }
    }
    
    public func appendEntry(for account: BareJID, jid: BareJID, state: State, authorJid: BareJID?, authorNickname: String? = nil, itemType: ItemType = ItemType.message, data: String, timestamp: Date, id: String?, chatState: ChatState? = nil, errorCondition: ErrorCondition? = nil, errorMessage: String? = nil, encryption: MessageEncryption, encryptionFingerprint: String?, fromArchive: Bool, carbonAction: MessageCarbonsModule.Action?, nicknameInRoom: String?, callback: @escaping (Int)->Void) {
        dispatcher.async {
            guard !state.isError || id == nil || !self.processOutgoingError(for: account, with: jid, stanzaId: id!, errorCondition: errorCondition, errorMessage: errorMessage) else {
                return;
            }
            
            guard !self.checkItemAlreadyAdded(for: account, with: jid, authorNickname: authorNickname, itemType: itemType, timestamp: timestamp, stanzaId: id, data: data) else {
                return;
            }
            
            let params:[String:Any?] = ["account" : account, "jid" : jid, "author_jid" : authorJid, "author_nickname": authorNickname, "timestamp": timestamp, "item_type": itemType.rawValue, "data": data, "state": state.rawValue, "stanza_id": id, "encryption": encryption.rawValue, "fingerprint": encryptionFingerprint]
            let msgId = try! self.msgAppendStmt.insert(params);
            let cu_params:[String:Any?] = ["account" : account, "jid" : jid, "timestamp" : timestamp ];
            _ = try! self.chatUpdateTimestamp.update(cu_params);

            DispatchQueue.main.async {
                var userInfo:[AnyHashable: Any] = ["account": account, "sender": jid, "incoming": state.direction == .incoming, "timestamp": timestamp, "body": data, "state": state, "encryption": encryption, "msgId": msgId!] ;

                
                // FIXME: are those neeeded?
                userInfo["senderName"] = authorNickname;
                userInfo["roomNickname"] = nicknameInRoom;
                if nicknameInRoom != nil {
                    userInfo["type"] = "muc";
                }
                userInfo["carbonAction"] = carbonAction?.rawValue;
                userInfo["fromArchive"] = fromArchive;

                NotificationCenter.default.post(name: DBChatHistoryStore.MESSAGE_NEW, object: nil, userInfo: userInfo);
                AccountSettings.MessageSyncTime(account.description).set(date: timestamp, condition: ComparisonResult.orderedAscending);


                callback(msgId!);
            }
        }
    }

    fileprivate func appendEntryOld(for account: BareJID, jid: BareJID, state: State, authorJid: BareJID?, authorNickname: String? = nil, itemType: ItemType = ItemType.message, data: String, timestamp: Date, id: String?, encryption: MessageEncryption, encryptionFingerprint: String?, callback: @escaping (Int)->Void) {
        ifNotEntryAlreadyAdded(for: account, jid: jid, authorJid: nil, itemType: itemType, data: data, timestamp: timestamp, id: id) {
            let params:[String:Any?] = ["account" : account, "jid" : jid, "author_jid" : authorJid, "author_nickname": authorNickname, "timestamp": timestamp, "item_type": itemType.rawValue, "data": data, "state": state.rawValue, "stanza_id": id, "encryption": encryption.rawValue, "fingerprint": encryptionFingerprint]
            let msgId = try! self.msgAppendStmt.insert(params);
            let cu_params:[String:Any?] = ["account" : account, "jid" : jid, "timestamp" : timestamp ];
            _ = try! self.chatUpdateTimestamp.update(cu_params);
            
            
            DispatchQueue.main.async {
                callback(msgId!);
            }
        }
    }

    fileprivate func ifNotEntryAlreadyAdded(for account: BareJID, jid: BareJID, authorJid: BareJID?, authorNickname: String? = nil, itemType: ItemType, data: String, timestamp: Date, id: String?, callback: @escaping ()->Void) {
        let range = id == nil ? 5.0 : 60.0;
        let ts_from = timestamp.addingTimeInterval(-60 * range);
        let ts_to = timestamp.addingTimeInterval(60 * range);
        
        let params:[String:Any?] = ["account": account, "jid": jid, "ts_from": ts_from, "ts_to": ts_to, "item_type": itemType.rawValue, "data": data, "stanza_id": id, "author_jid": authorJid, "author_nickname": authorNickname];
        msgAlreadyAddedStmt.dispatcher.async {
            if try! self.msgAlreadyAddedStmt.scalar(params) == 0 {
                callback();
            }
        }
    }
    
    fileprivate func checkItemAlreadyAdded(for account: BareJID, with jid: BareJID, authorNickname: String? = nil, itemType: ItemType, timestamp: Date, stanzaId id: String?, data: String?) -> Bool {
        let range = id == nil ? 5.0 : 60.0;
        let ts_from = timestamp.addingTimeInterval(-60 * range);
        let ts_to = timestamp.addingTimeInterval(60 * range);
        
        let params:[String:Any?] = ["account": account, "jid": jid, "ts_from": ts_from, "ts_to": ts_to, "item_type": itemType.rawValue, "data": data, "stanza_id": id, "author_jid": nil, "author_nickname": authorNickname];
        return try! (self.msgAlreadyAddedStmt.scalar(params) ?? 0) > 0;
    }
    
    open func countMessages(for account:BareJID, with jid:BareJID) -> Int {
        let params:[String:Any?] = ["account":account, "jid":jid];
        return try! msgsCountStmt.scalar(params) ?? 0;
    }
    
    open func forEachMessage(stmt: DBStatement, account:BareJID, jid:BareJID, limit:Int, offset: Int, forEach: (_ cursor:DBCursor)->Void) {
        let params:[String:Any?] = ["account":account, "jid":jid, "limit": limit, "offset": offset];
        try! stmt.query(params, forEach: forEach);
    }
    
    open func getMessagesStatementForAccountAndJid() -> DBStatement {
        return try! self.dbConnection.prepareStatement(DBChatHistoryStore.CHAT_MSGS_GET);
    }
    
    open func getMessagePosition(for account: BareJID, with jid: BareJID, msgId: Int, inverted: Bool) -> Int {
        let params:[String:Any?] = ["account":account, "jid":jid, "msgId":msgId];
        if inverted {
            return try! getMessagePositionStmtInverted.scalar(params)!;
        } else {
            return try! getMessagePositionStmt.scalar(params)!;
        }
    }
    
    open func getMessageError(msgId: Int, handler: @escaping (String?)->Void) {
        let error: String? = try! self.getMessageErrorDetails.findFirst(msgId) { cursor in cursor["error"] };
        handler(error);
    }
    
    open func checkLastMessageTimeFor(account: BareJID, callback: @escaping (Date?, String?)->Void) {
        let params: [String:Any?] = ["account": account.description];
        let date: Date? = try! self.lastMessageTimestampForAccount.findFirst(params) { cursor in cursor["timestamp"] };
        let msgId: String? = nil;
        DispatchQueue.global().async {
            callback(date, msgId);
        }
    }
    
    open func handle(event:Event) {
        switch event {
        case let e as MessageModule.MessageReceivedEvent:
            appendMessage(for: e.sessionObject, message: e.message);
        case let e as MessageCarbonsModule.CarbonReceivedEvent:
            appendMessage(for: e.sessionObject, message: e.message, carbonAction: e.action);
        case let e as MucModule.MessageReceivedEvent:
            appendMucMessage(event: e);
        case let e as MessageArchiveManagementModule.ArchivedMessageReceivedEvent:
            appendMessage(event: e);
        case let e as MessageDeliveryReceiptsModule.ReceiptEvent:
            updateMessageState(event: e);
        default:
            log("received unsupported event", event);
        }
    }
    
    fileprivate func updateMessageState(event: MessageDeliveryReceiptsModule.ReceiptEvent) {
        guard let account = event.message.to?.bareJid ?? event.sessionObject.userBareJid, let jid = event.message.from?.bareJid else {
            return;
        }
        changeMessageState(account: account, jid: jid, stanzaId: event.messageId, oldState: State.outgoing, newState: State.outgoing_delivered, completion: {(msgId) in
            NotificationCenter.default.post(name: DBChatHistoryStore.MESSAGE_UPDATED, object: self, userInfo: ["message-id": msgId, "state": State.outgoing_delivered]);
        });
    }
    
    open func countUnreadChats(onResult: @escaping (Int)->Void) {
        msgsCountUnreadChatsStmt.dispatcher.async {
            let value = try! self.msgsCountUnreadChatsStmt.scalar() ?? 0;
            onResult(value);
        }
    }
    
    open func forEachUnreadChat(forEach: (_ account: BareJID, _ jid: BareJID)->Void) {
        try! listUnreadChatsStmt.query(forEach: { (cursor) -> Void in
            let account: BareJID = cursor["account"]!;
            let jid: BareJID = cursor["jid"]!;
            forEach(account, jid);
        });
    }
    
    open func markAsRead(for account: BareJID, with jid: BareJID) {
        let params:[String:Any?] = ["account":account, "jid":jid];
        let updatedRecords = try! self.msgsMarkAsReadStmt.update(params);
        if updatedRecords > 0 {
            DispatchQueue.global(qos: .default).async() {
                self.chatItemsChanged(for: account, with: jid, action: "markedRead");
            }
        }
    }
    
    open func updatePreview(msgId: Int, preview: String?, completion: ((Int)->Void)?) {
        let params: [String:Any?] = ["id": msgId, "preview": preview];
        if try! self.msgUpdatePreviewStmt.update(params) > 0 {
            DispatchQueue.global().async {
                completion?(msgId);
            }
        }
    }
    
    fileprivate func changeMessageState(account: BareJID, jid: BareJID, stanzaId: String, oldState: State, newState: State, completion: ((Int)->Void)?) {
        dispatcher.async {
            guard let msgId = self.getMessageIdInt(account: account, jid: jid, stanzaId: stanzaId) else {
                return;
            }
            let params: [String: Any?] = ["id": msgId, "oldState": oldState.rawValue, "newState": newState.rawValue];
            if try! self.msgUpdateStateStmt.update(params) > 0 {
                DispatchQueue.global().async {
                    completion?(msgId);
                }
            }
        }
    }
    
    fileprivate func getMessageIdInt(account: BareJID, jid: BareJID, stanzaId: String?) -> Int? {
        guard stanzaId != nil else {
            return nil;
        }
        let idParams: [String: Any?] = ["account": account, "jid": jid, "stanzaId": stanzaId!];
        guard let msgId = try! self.msgGetIdWithAccountPariticipantAndStanzaIdStmt.scalar(idParams) else {
            return nil;
        }

        return msgId;
    }
    
    open func deleteMessages(for account: BareJID, with jid: BareJID) {
        let params:[String:Any?] = ["account":account, "jid":jid];
        _ = try! self.msgsDeleteStmt.update(params);
    }
    
    @objc open func accountRemoved(_ notification: NSNotification) {
        if let data = notification.userInfo {
            let accountStr = data["account"] as! String;
            _ = try! dbConnection.prepareStatement("DELETE FROM chat_history WHERE account = ?").update(accountStr);
        }
    }
    
    @objc open func imageRemovedFromCache(_ notification: NSNotification) {
        if let data = notification.userInfo {
            let url = data["url"] as! URL;
            _ = try! dbConnection.prepareStatement("UPDATE chat_history SET preview = null WHERE preview = ?").update("preview:image:\(url.pathComponents.last!)");
        }
    }
    
    fileprivate func chatItemsChanged(for account: BareJID, with jid: BareJID, action: String) {
        let userInfo:[AnyHashable: Any] = ["account":account, "jid":jid, "action":action];
        NotificationCenter.default.post(name: DBChatHistoryStore.CHAT_ITEMS_UPDATED, object: nil, userInfo: userInfo);
    }
    
    public enum State:Int {
        case incoming = 0
        case outgoing = 1
        case incoming_unread = 2
        case outgoing_unsent = 3
        case outgoing_delivered = 4
        case outgoing_read = 5
        case outgoing_error_unread = 6
        case outgoing_error = 7
        case incoming_error_unread = 8
        case incoming_error = 9
        
        var direction: MessageDirection {
            switch self {
            case .incoming, .incoming_unread, .incoming_error_unread, .incoming_error:
                return .incoming;
            case .outgoing, .outgoing_unsent, .outgoing_delivered, .outgoing_read, .outgoing_error_unread, .outgoing_error:
                return .outgoing;
            }
        }
        
        var state: MessageState {
            switch self {
            case .incoming, .outgoing_read:
                return .read;
            case .incoming_unread, .outgoing_delivered:
                return .delivered;
            case .outgoing_unsent:
                return .unsent;
            case .outgoing:
                return .sent;
            case .incoming_error, .incoming_error_unread, .outgoing_error, .outgoing_error_unread:
                return .error;
            }
        }
        
        var isError: Bool {
            return state == .error;
        }
    }
    
    public enum MessageDirection {
        case incoming
        case outgoing
    }
    
    public enum MessageState {
        case unsent
        case sent
        case delivered
        case read
        case error
    }
    
    public enum ItemType:Int {
        case message = 0
    }
}
