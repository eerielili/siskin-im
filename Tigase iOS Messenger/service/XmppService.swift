//
// XmppService.swift
//
// Tigase iOS Messenger
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//


import UIKit
import TigaseSwift

open class XmppService: Logger, EventHandler {
    
    open static let SERVER_CERTIFICATE_ERROR = Notification.Name("serverCertificateError");
    open static let AUTHENTICATION_FAILURE = Notification.Name("authenticationFailure");
    open static let PRESENCE_AUTHORIZATION_REQUEST = Notification.Name("presenceAuthorizationRequest");
    open static let ACCOUNT_STATE_CHANGED = Notification.Name("accountStateChanged");
    
    open var fetchTimeShort: TimeInterval = 5;
    open var fetchTimeLong: TimeInterval = 20;
    
    open static let pushServiceJid = JID("push.tigase.im");
    
    fileprivate static let CONNECTION_RETRY_NO_KEY = "CONNECTION_RETRY_NO_KEY";
    
    fileprivate var creationDate = NSDate();
    fileprivate var fetchClientsWaitingForReconnection: [BareJID] = [];
    fileprivate var fetchStart = NSDate();
    
    fileprivate let dbConnection: DBConnection;
    open var avatarManager: AvatarManager!;
    open let dbCapsCache: DBCapabilitiesCache;
    open let dbChatStore: DBChatStore;
    open let dbChatHistoryStore: DBChatHistoryStore;
    fileprivate let dbRosterStore: DBRosterStore;
    open let dbVCardsCache: DBVCardsCache;
    fileprivate let avatarStore: AvatarStore;
    open var applicationState: ApplicationState {
        didSet {
            if oldValue != applicationState {
                applicationStateChanged();
            }
            if applicationState != .active {
                avatarManager.clearCache();
                ImageCache.shared.clearInMemoryCache();
            }
        }
    }
    
    fileprivate let reachability: Reachability;
    
    fileprivate var clients = [BareJID:XMPPClient]();
    
    fileprivate var eventHandlers: [EventHandlerHolder] = [];
    
    fileprivate var networkAvailable:Bool {
        didSet {
            if networkAvailable {
                if !oldValue {
                    connectClients();
                } else {
                    keepalive();
                }
            } else if !networkAvailable && oldValue {
                disconnectClients(force: true);
            }
        }
    }
    
    fileprivate var backgroundFetchCompletionHandler: ((UIBackgroundFetchResult)->Void)?;
    fileprivate var backgroundFetchTimer: TigaseSwift.Timer?;
    
    fileprivate var sslCertificateValidator: ((SessionObject,SecTrust) -> Bool)?;
    
    init(dbConnection:DBConnection) {
        self.dbConnection = dbConnection;
        self.dbCapsCache = DBCapabilitiesCache(dbConnection: dbConnection);
        self.dbChatStore = DBChatStore(dbConnection: dbConnection);
        self.dbChatHistoryStore = DBChatHistoryStore(dbConnection: dbConnection);
        self.dbRosterStore = DBRosterStore(dbConnection: dbConnection);
        self.dbVCardsCache = DBVCardsCache(dbConnection: dbConnection);
        self.avatarStore = AvatarStore(dbConnection: dbConnection);
        self.reachability = Reachability();
        self.networkAvailable = false;
        self.applicationState = UIApplication.shared.applicationState == .active ? .active : .inactive;

        super.init();

        self.sslCertificateValidator = {(sessionObject: SessionObject, trust: SecTrust) -> Bool in
            return self.validateSslCertificate(sessionObject, trust: trust);
        };

        self.avatarManager = AvatarManager(xmppService: self, store: avatarStore);
        NotificationCenter.default.addObserver(self, selector: #selector(XmppService.accountConfigurationChanged), name: AccountManager.ACCOUNT_CONFIGURATION_CHANGED, object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(XmppService.connectivityChanged), name: Reachability.CONNECTIVITY_CHANGED, object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(XmppService.settingsChanged), name: Settings.SETTINGS_CHANGED, object: nil);
        networkAvailable = reachability.isConnectedToNetwork();
    
    }
    
    open func updateXmppClientInstance() {
        for account in AccountManager.getAccounts() {
            updateXmppClientInstance(forJid: BareJID(account));
        }
    }
    
    open func updateXmppClientInstance(forJid userJid:BareJID) {
        print("updating xmppclient instance for", userJid);
        var client = clients[userJid];
        let password = AccountManager.getAccountPassword(forJid: userJid.stringValue);
        let config = AccountManager.getAccount(forJid: userJid.stringValue);
        
        if client == nil {
            if password == nil || config == nil || config?.active != true {
                return;
            }
            client = XMPPClient()
            client!.keepaliveTimeout = 0;
            registerModules(client!);
            registerEventHandlers(client!);
            
            client?.sessionObject.setUserProperty(SocketConnector.SSL_CERTIFICATE_VALIDATOR, value: self.sslCertificateValidator);
            
            DispatchQueue.global(qos: .default).async {
                NotificationCenter.default.post(name: XmppService.ACCOUNT_STATE_CHANGED, object: self, userInfo: ["account":userJid.stringValue]);
            }
        } else {
            if client?.state != SocketConnector.State.disconnected {
                client?.disconnect();
                return;
            }
            
            if password == nil || config == nil || config?.active != true {
                clients.removeValue(forKey: userJid);
                unregisterEventHandlers(client!);
                DispatchQueue.global(qos: .default).async {
                    NotificationCenter.default.post(name: XmppService.ACCOUNT_STATE_CHANGED, object: self, userInfo: ["account":userJid.stringValue]);
                }
                return;
            }
            
        }
        
        client?.connectionConfiguration.setUserJID(userJid);
        client?.connectionConfiguration.setUserPassword(password);
        
        // Setting resource to use - using device name
        client?.sessionObject.setUserProperty(SessionObject.RESOURCE, value: UIDevice.current.name);
        
        // Setting software name, version and OS name
        client?.sessionObject.setUserProperty(SoftwareVersionModule.NAME_KEY, value: Bundle.main.infoDictionary!["CFBundleName"] as! String);
        client?.sessionObject.setUserProperty(SoftwareVersionModule.VERSION_KEY, value: Bundle.main.infoDictionary!["CFBundleVersion"] as! String);
        client?.sessionObject.setUserProperty(SoftwareVersionModule.OS_KEY, value: UIDevice.current.systemName);
        
        if let pushModule: TigasePushNotificationsModule = client?.modulesManager.getModule(TigasePushNotificationsModule.ID) {
            pushModule.pushServiceJid = config?.pushServiceJid ?? XmppService.pushServiceJid;
            pushModule.pushServiceNode = config?.pushServiceNode;
            pushModule.deviceId = Settings.DeviceToken.getString();
            pushModule.enabled = config?.pushNotifications ?? false;
        }
        
        clients[userJid] = client;
        
        if networkAvailable && (applicationState == .active || (config?.pushNotifications ?? false) == false) {
            let retryNo = client!.sessionObject.getProperty(XmppService.CONNECTION_RETRY_NO_KEY, defValue: 0) - 2;
            if (retryNo > 0) {
                let delay = min((Double(retryNo) * 5.0), 30.0);
                print("scheduling reconnection", retryNo, "after", delay, "seconds");
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: {
                    client?.login();
                });
            } else {
                client?.login();
            }
        } else {
            client?.modulesManager.initIfRequired();
        }
    }
    
    open func getClients(filter: ((XMPPClient)->Bool)? = nil) -> [XMPPClient] {
        return clients.values.filter(filter ?? { (client) -> Bool in
            return true;
            });
    }
    
    open func getClient(forJid account:BareJID) -> XMPPClient? {
        return clients[account];
    }
    
    fileprivate func registerModules(_ client:XMPPClient) {
        let smModule = client.modulesManager.register(StreamManagementModule());
        smModule.maxResumptionTimeout = 3600;
        _ = client.modulesManager.register(AuthModule());
        _ = client.modulesManager.register(StreamFeaturesModule());
        _ = client.modulesManager.register(SaslModule());
        _ = client.modulesManager.register(ResourceBinderModule());
        _ = client.modulesManager.register(SessionEstablishmentModule());
        _ = client.modulesManager.register(DiscoveryModule());
        _ = client.modulesManager.register(SoftwareVersionModule());
        _ = client.modulesManager.register(VCardTempModule());
        _ = client.modulesManager.register(VCard4Module());
        _ = client.modulesManager.register(ClientStateIndicationModule());
        _ = client.modulesManager.register(MobileModeModule());
        _ = client.modulesManager.register(PingModule());
        _ = client.modulesManager.register(PubSubModule());
        _ = client.modulesManager.register(PEPUserAvatarModule());
        let rosterModule =  client.modulesManager.register(RosterModule());
        rosterModule.rosterStore = DBRosterStoreWrapper(sessionObject: client.sessionObject, store: dbRosterStore);
        rosterModule.versionProvider = dbRosterStore;
        _ = client.modulesManager.register(PresenceModule());
        let messageModule = client.modulesManager.register(MessageModule());
        let chatManager = DefaultChatManager(context: client.context, chatStore: DBChatStoreWrapper(sessionObject: client.sessionObject, store: dbChatStore));
        messageModule.chatManager = chatManager;
        _ = client.modulesManager.register(MessageCarbonsModule());
        _ = client.modulesManager.register(MessageArchiveManagementModule());
        let mucModule = MucModule();
        mucModule.roomsManager = DBRoomsManager(store: dbChatStore);
        _ = client.modulesManager.register(mucModule);
        _ = client.modulesManager.register(AdHocCommandsModule());
        _ = client.modulesManager.register(TigasePushNotificationsModule(pushServiceJid: XmppService.pushServiceJid));
        _ = client.modulesManager.register(HttpFileUploadModule());
        _ = client.modulesManager.register(MessageDeliveryReceiptsModule());
        let capsModule = client.modulesManager.register(CapabilitiesModule());
        capsModule.cache = dbCapsCache;
    }
    
    fileprivate func registerEventHandlers(_ client:XMPPClient) {
        client.eventBus.register(handler: self, for: SocketConnector.DisconnectedEvent.TYPE, DiscoveryModule.ServerFeaturesReceivedEvent.TYPE, PresenceModule.BeforePresenceSendEvent.TYPE, PresenceModule.SubscribeRequestEvent.TYPE, SessionEstablishmentModule.SessionEstablishmentSuccessEvent.TYPE, SocketConnector.CertificateErrorEvent.TYPE, AuthModule.AuthFailedEvent.TYPE, StreamManagementModule.ResumedEvent.TYPE, MucModule.NewRoomCreatedEvent.TYPE);
        client.eventBus.register(handler: dbChatHistoryStore, for: MessageModule.MessageReceivedEvent.TYPE, MessageCarbonsModule.CarbonReceivedEvent.TYPE, MucModule.MessageReceivedEvent.TYPE, MessageArchiveManagementModule.ArchivedMessageReceivedEvent.TYPE, MessageDeliveryReceiptsModule.ReceiptEvent.TYPE);
        for holder in eventHandlers {
            client.eventBus.register(handler: holder.handler, for: holder.events);
        }
    }
    
    fileprivate func unregisterEventHandlers(_ client:XMPPClient) {
        client.eventBus.unregister(handler: self, for: SocketConnector.DisconnectedEvent.TYPE, DiscoveryModule.ServerFeaturesReceivedEvent.TYPE, PresenceModule.BeforePresenceSendEvent.TYPE, PresenceModule.SubscribeRequestEvent.TYPE, SessionEstablishmentModule.SessionEstablishmentSuccessEvent.TYPE, SocketConnector.CertificateErrorEvent.TYPE, AuthModule.AuthFailedEvent.TYPE, StreamManagementModule.ResumedEvent.TYPE, MucModule.NewRoomCreatedEvent.TYPE);
        client.eventBus.unregister(handler: dbChatHistoryStore, for: MessageModule.MessageReceivedEvent.TYPE, MessageCarbonsModule.CarbonReceivedEvent.TYPE, MucModule.MessageReceivedEvent.TYPE, MessageArchiveManagementModule.ArchivedMessageReceivedEvent.TYPE, MessageDeliveryReceiptsModule.ReceiptEvent.TYPE);
        for holder in eventHandlers {
            client.eventBus.unregister(handler: holder.handler, for: holder.events);
        }
    }
    
    open func handle(event: Event) {
        switch event {
        case let e as SocketConnector.CertificateErrorEvent:
            // at first let's disable account so it will not try to reconnect
            // until user will take action
            let certCount = SecTrustGetCertificateCount(e.trust);
            print("cert count", certCount);
            
            var certInfo: [String: AnyObject] = [:];
            
            for i in 0..<certCount {
                let cert = SecTrustGetCertificateAtIndex(e.trust, i);
                let fingerprint = Digest.sha1.digest(toHex: SecCertificateCopyData(cert!) as Data);
                // on first cert got 03469208e5d8e580f65799497d73b2d3098e8c8a
                // while openssl reports: SHA1 Fingerprint=03:46:92:08:E5:D8:E5:80:F6:57:99:49:7D:73:B2:D3:09:8E:8C:8A
                let summary = SecCertificateCopySubjectSummary(cert!)
                print("cert", cert!, "SUMMARY:", summary, "fingerprint:", fingerprint);
                switch i {
                case 0:
                    certInfo["cert-name"] = summary;
                    certInfo["cert-hash-sha1"] = fingerprint as NSString?;
                case 1:
                    certInfo["issuer-name"] = summary;
                    certInfo["issuer-hash-sha1"] = fingerprint as NSString?;
                default:
                    break;
                }
            }
            print("cert info =", certInfo);
            
            if let account = AccountManager.getAccount(forJid: e.sessionObject.userBareJid!.stringValue) {
                account.active = false;
                account.serverCertificate = certInfo;
                AccountManager.updateAccount(account, notifyChange: false);
            }
            
            var info = certInfo;
            info["account"] = e.sessionObject.userBareJid!.stringValue as NSString;
            AccountSettings.LastError(e.sessionObject.userBareJid!.stringValue).set(string: "cert");
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: XmppService.SERVER_CERTIFICATE_ERROR, object: self, userInfo: info);
            }
        case let e as SocketConnector.DisconnectedEvent:
            increaseBackgroundFetchTimeIfNeeded();
            networkAvailable = reachability.isConnectedToNetwork();
            if let jid = e.sessionObject.userBareJid {
                DispatchQueue.global(qos: .default).async {
                    NotificationCenter.default.post(name: XmppService.ACCOUNT_STATE_CHANGED, object: self, userInfo: ["account":jid.stringValue]);
                    if let client = self.getClient(forJid: jid) {
                        let retryNo = client.sessionObject.getProperty(XmppService.CONNECTION_RETRY_NO_KEY, defValue: 0) + 1;
                        client.sessionObject.setProperty(XmppService.CONNECTION_RETRY_NO_KEY, value: retryNo);
                        self.updateXmppClientInstance(forJid: jid);
                    }
                }
            }
        case let e as DiscoveryModule.ServerFeaturesReceivedEvent:
            if e.features.contains(MessageCarbonsModule.MC_XMLNS) {
                if let messageCarbonsModule: MessageCarbonsModule = getClient(forJid: e.sessionObject.userBareJid!)?.modulesManager.getModule(MessageCarbonsModule.ID) {
                    if Settings.EnableMessageCarbons.getBool() {
                        messageCarbonsModule.enable();
                    }
                }
            }
        case let e as PresenceModule.BeforePresenceSendEvent:
            if applicationState == .active {
                e.presence.show = Presence.Show.online;
                e.presence.priority = 5;
            } else {
                e.presence.show = Presence.Show.away;
                e.presence.priority = 0;
            }
            if let manualShow = Settings.StatusType.getString() {
                e.presence.show = Presence.Show(rawValue: manualShow);
            }
            e.presence.status = Settings.StatusMessage.getString();
        case let e as PresenceModule.SubscribeRequestEvent:
            var info: [String: AnyObject] = [:];
            info["account"] = e.sessionObject.userBareJid!;
            info["sender"] = e.presence.from!.bareJid;
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: XmppService.PRESENCE_AUTHORIZATION_REQUEST, object: self, userInfo: info);
            }
        case let e as SessionEstablishmentModule.SessionEstablishmentSuccessEvent:
            let account = e.sessionObject.userBareJid!;
            if AccountSettings.MessageSyncAutomatic(account.description).getBool() {
                let messageSyncPeriod = AccountSettings.MessageSyncPeriod(account.description).getDouble();
                if messageSyncPeriod > 0 {
                    if let messageSyncTime = AccountSettings.MessageSyncTime(account.description).getDate() {
                        syncMessages(account: account, start: messageSyncTime);
                    } else {
                        var start = Date().addingTimeInterval(-1 * messageSyncPeriod * 60 * 60);
                        self.syncMessages(account: account, start: start);
                    }
                }
            }

            let client = getClient(forJid: e.sessionObject.userBareJid!);
            client?.sessionObject.setProperty(XmppService.CONNECTION_RETRY_NO_KEY, value: nil);
            DispatchQueue.global(qos: .default).async {
                NotificationCenter.default.post(name: XmppService.ACCOUNT_STATE_CHANGED, object: self, userInfo: ["account":e.sessionObject.userBareJid!.stringValue]);
            }
            if applicationState == .inactive {
                let csiModule: ClientStateIndicationModule? = client?.modulesManager.getModule(ClientStateIndicationModule.ID);
                if csiModule != nil && csiModule!.available {
                    _ = csiModule!.setState(applicationState == .active);
                }
                else if let mobileModeModule: MobileModeModule = client?.modulesManager.getModule(MobileModeModule.ID) {
                    mobileModeModule.enable();
                }
            }
            reconnectMucRooms(forAccountJid: e.sessionObject.userBareJid!);
        case let e as AuthModule.AuthFailedEvent:
            if e.error != SaslError.aborted {
                if let account = AccountManager.getAccount(forJid: e.sessionObject.userBareJid!.stringValue) {
                    account.active = false;
                    AccountManager.updateAccount(account, notifyChange: true);
                }
                var info: [String: AnyObject] = [:];
                info["account"] = e.sessionObject.userBareJid!.stringValue as NSString;
                info["auth-error-type"] = e.error.rawValue as NSString;
                AccountSettings.LastError(e.sessionObject.userBareJid!.stringValue).set(string: "auth");
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: XmppService.AUTHENTICATION_FAILURE, object: self, userInfo: info);
                }
            } else {
                self.updateXmppClientInstance(forJid: e.sessionObject.userBareJid!);
            }
        case let e as StreamManagementModule.ResumedEvent:
            let client = getClient(forJid: e.sessionObject.userBareJid!);
            client?.sessionObject.setProperty(XmppService.CONNECTION_RETRY_NO_KEY, value: nil);
            let csiModule: ClientStateIndicationModule? = client?.modulesManager.getModule(ClientStateIndicationModule.ID);
            if csiModule != nil && csiModule!.available {
                _ = csiModule!.setState(applicationState == .active);
            }
            else if let mobileModeModule: MobileModeModule = client?.modulesManager.getModule(MobileModeModule.ID) {
                _ = mobileModeModule.setState(applicationState == .inactive);
            }
            
            DispatchQueue.global(qos: .default).async {
                NotificationCenter.default.post(name: XmppService.ACCOUNT_STATE_CHANGED, object: self, userInfo: ["account":e.sessionObject.userBareJid!.stringValue]);
            }

            // here we should notify messenger that connection was resumed and we can end soon
            self.clientConnected(account: e.sessionObject.userBareJid!);
        case let e as MucModule.NewRoomCreatedEvent:
            guard let mucModule:MucModule = self.getClient(forJid: e.sessionObject.userBareJid!)?.context.modulesManager.getModule(MucModule.ID) else {
                return;
            }
            mucModule.getRoomConfiguration(roomJid: e.room.jid, onSuccess: {(config) in
                mucModule.setRoomConfiguration(roomJid: e.room.jid, configuration: config, onSuccess: {
                    self.log("unlocked room", e.room.jid);
                }, onError: nil);
            }, onError: nil);
        default:
            log("received unsupported event", event);
        }
    }
    
    open func keepalive() {
        for client in clients.values {
            client.keepalive();
        }
    }
    
    fileprivate func applicationStateChanged() {
        sendAutoPresence();
        for client in clients.values {
            if client.state == .connected {
                let csiModule: ClientStateIndicationModule? = client.modulesManager.getModule(ClientStateIndicationModule.ID);
                if csiModule != nil && csiModule!.available {
                    _ = csiModule!.setState(applicationState == .active);
                }
                else if let mobileModeModule: MobileModeModule = client.modulesManager.getModule(MobileModeModule.ID) {
                    _ = mobileModeModule.setState(applicationState == .inactive);
                }
            }
        }
        if applicationState == .active {
            for client in clients.values {
                client.sessionObject.setProperty(XmppService.CONNECTION_RETRY_NO_KEY, value: nil);
                if client.state == .disconnected { // && client.pushNotificationsEnabled {
                    client.login();
                    //updateXmppClientInstance(forJid: client.sessionObject.userBareJid!);
                }
            }
        }
    }
    
    fileprivate func sendAutoPresence() {
        for client in clients.values {
            if client.state == .connected {
                if let presenceModule: PresenceModule = client.modulesManager.getModule(PresenceModule.ID) {
                    presenceModule.setPresence(show: .online, status: nil, priority: nil);
                }
            }
        }
    }
    
    open func registerEventHandler(_ handler:EventHandler, for events:Event...) {
        log("registered event handler", handler, "for", events);
        eventHandlers.append(EventHandlerHolder(handler: handler, events: events));
        for client in clients.values {
            client.eventBus.register(handler: handler, for: events);
        }
    }
    
    open func unregisterEventHandler(_ handler:EventHandler, for events:Event...) {
        if let idx = eventHandlers.index(where: { (holder) -> Bool in
            return holder.matches(handler, events: events);
        }) {
            log("removed event handler", handler, "for", events);
            eventHandlers.remove(at: idx);
        } else {
            log("failed to remove event handler", handler, "for", events);
        }
        for client in clients.values {
            client.eventBus.unregister(handler: handler, for: events);
        }
    }
    
    @objc open func accountConfigurationChanged(_ notification: NSNotification) {
        let accountName = notification.userInfo!["account"] as! String;
        let jid = BareJID(accountName);
        updateXmppClientInstance(forJid: jid);
    }
    
    @objc open func connectivityChanged(_ notification: NSNotification) {
        self.networkAvailable = notification.userInfo!["connected"] as! Bool;
    }
    
    @objc open func settingsChanged(_ notification: NSNotification) {
        guard let setting = Settings(rawValue: notification.userInfo!["key"] as! String) else {
            return;
        }
        switch setting {
        case .EnableMessageCarbons:
            let value = setting.getBool();
            for client in clients.values {
                if client.state == .connected {
                    let messageCarbonsModule: MessageCarbonsModule? = client.modulesManager.getModule(MessageCarbonsModule.ID);
                    messageCarbonsModule?.setState(value, callback: nil);
                }
            }
        case .StatusMessage, .StatusType:
            sendAutoPresence();
        case .DeviceToken:
            let newDeviceId = notification.userInfo?["newValue"] as? String;
            for client in clients.values {
                if let pushModule: TigasePushNotificationsModule = client.modulesManager.getModule(PushNotificationsModule.ID) {
                    pushModule.deviceId = newDeviceId;
                }
            }
        default:
            break;
        }
    }
    
    open func backgroundTaskFinished() -> Bool {
        guard applicationState != .active else {
            return false;
        }
        var stopping = 0;
        for client in clients.values {
            if client.state == .connected && client.pushNotificationsEnabled {
                // we need to close connection so that push notifications will be delivered to us!
                // this is in generic case, some severs may have optimizations to improve this
                client.disconnect();
                stopping += 1;
            }
        }
        return stopping > 0;
    }
    
    open func preformFetch(for account: BareJID? = nil, _ completionHandler: @escaping (UIBackgroundFetchResult)->Void) {
        guard applicationState != .active else {
            print("skipping background fetch as application is active");
            completionHandler(.newData);
            return;
        }
        guard networkAvailable == true else {
            print("skipping background fetch as network is not available");
            completionHandler(.failed);
            return;
        }
        // count connections which needs to resume
        var countLong = 0;
        var countShort = 0;
        self.fetchStart = NSDate();
        self.fetchClientsWaitingForReconnection = [];
        if (account != nil) {
            if let client = getClient(forJid: account!) {
                if client.state != .connected {
                    if !client.pushNotificationsEnabled {
                        self.fetchClientsWaitingForReconnection.append(client.sessionObject.userBareJid!);
                        countLong += 1;
                    }
                } else {
                    client.keepalive();
                    countShort += 1;
                }
            } else {
                completionHandler(.failed);
                return;
            }
        } else {
            for client in clients.values {
                // try to send keepalive to ensure connection is valid
                // if it fails it will try to resume connection
                if client.state != .connected {
                    if !client.pushNotificationsEnabled {
                        self.fetchClientsWaitingForReconnection.append(client.sessionObject.userBareJid!);
                        countLong += 1;
                    }
                // it looks like this is causing an issue
//                if client.state == .disconnected {
//                    client.login();
//                }
                } else {
                    client.keepalive();
                    countShort += 1;
                }
            }
        }
        
        log("waiting for clients", self.fetchClientsWaitingForReconnection, "to reconnect");
        // we need to give connections time to read and process data
        // so event if all are connected lets wait 5secs
        guard countLong > 0 || countShort > 0 else {
            // only push based connections!
            completionHandler(.newData);
            return;
        }
        self.backgroundFetchCompletionHandler = completionHandler;
        backgroundFetchTimer = TigaseSwift.Timer(delayInSeconds: countLong > 0 ? fetchTimeLong : fetchTimeShort, repeats: false, callback: {
            self.backgroundFetchTimedOut();
        });
    }
    
    fileprivate func syncMessages(account: BareJID, start: Date?, rsmQuery: RSM.Query? = nil) {
        if let client = self.getClient(forJid: account) {
            if let mamModule: MessageArchiveManagementModule = client.modulesManager.getModule(MessageArchiveManagementModule.ID) {
                //let rsmQuery = RSM.Query(max: 100);
                
                mamModule.queryItems(start: start, queryId: "archive-1", rsm: rsmQuery ?? RSM.Query(lastItems: 100), onSuccess: {(queryid,complete,rsmResponse) in
                    self.log("received items from archive", queryid, complete, rsmResponse);
                    if rsmResponse != nil && rsmResponse!.index != 0 && rsmResponse?.first != nil {
                        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1){
                            self.syncMessages(account: account, start: start, rsmQuery: rsmResponse?.previous(100));
                        }
                    }
                }, onError: {(error,stanza) in
                    self.log("failed to retrieve items from archive", error, stanza);
                });
            }
        }
    }
    
    fileprivate func clientConnected(account: BareJID) {
        DispatchQueue.main.async {
            self.log("conencted client for account", account);
            if let idx = self.fetchClientsWaitingForReconnection.index(of: account) {
                self.fetchClientsWaitingForReconnection.remove(at: idx);
                self.log("still waiting for accounts to reconnect", self.fetchClientsWaitingForReconnection);
                if (self.fetchClientsWaitingForReconnection.isEmpty && ((self.fetchTimeLong - 4) + self.fetchStart.timeIntervalSinceNow) > 0) {
                    self.backgroundFetchTimer?.cancel();
                    self.backgroundFetchTimer = TigaseSwift.Timer(delayInSeconds: 2, repeats: false, callback: {
                        self.backgroundFetchTimedOut();
                    })
                }
            }
        }
    }

    fileprivate func backgroundFetchTimedOut() {
        let callback = backgroundFetchCompletionHandler;
        backgroundFetchCompletionHandler = nil;
        if applicationState != .active {
            // do not close here - may be race condtion with opening of an app!
            //disconnectClients(true);
            for client in clients.values {
                if client.state == .connected {
                    if let streamManagement:StreamManagementModule = client.modulesManager.getModule(StreamManagementModule.ID) {
                        streamManagement.sendAck();
                    } else {
                        client.keepalive();
                    }
                }
            }
        }
        self.fetchClientsWaitingForReconnection = [];
        callback?(.newData);
    }
    
    fileprivate func increaseBackgroundFetchTimeIfNeeded() {
        let timeout = backgroundFetchTimer?.timeout;
        if timeout != nil && timeout! < fetchTimeLong {
            let callback = backgroundFetchTimer!.callback;
            if callback != nil {
                backgroundFetchTimer?.cancel();
                backgroundFetchTimer = TigaseSwift.Timer(delayInSeconds: min(UIApplication.shared.backgroundTimeRemaining - 5, fetchTimeLong), repeats: false, callback: callback!);
            }
        }
    }
    
    fileprivate func connectClients(force: Bool = true) {
        for client in clients.values {
            client.sessionObject.setProperty(XmppService.CONNECTION_RETRY_NO_KEY, value: nil);
            client.login();
        }
    }
    
    fileprivate func disconnectClients(force:Bool = false) {
        for client in clients.values {
            client.disconnect(force);
        }
    }
    
    fileprivate func reconnectMucRooms(forAccountJid jid: BareJID) {
        if let client = getClient(forJid: jid) {
            guard client.state == .connected else {
                return;
            }
            if let mucModule: MucModule = client.modulesManager.getModule(MucModule.ID) {
                DispatchQueue.global(qos: .background).async {
                    for room in mucModule.roomsManager.getRooms() {
                        if room.state != .joined {
                            _ = room.rejoin();
                        }
                    }
                }
            }
        }
    }
    
    var accepedCertificates = [String]();
    
    fileprivate func validateSslCertificate(_ sessionObject: SessionObject, trust: SecTrust) -> Bool {
        let policy = SecPolicyCreateSSL(false, sessionObject.userBareJid?.domain as CFString?);
        var secTrustResultType = SecTrustResultType.invalid;
        SecTrustSetPolicies(trust, policy);
        SecTrustEvaluate(trust, &secTrustResultType);

        var valid = (secTrustResultType == SecTrustResultType.proceed || secTrustResultType == SecTrustResultType.unspecified);
        if !valid {
            let certCount = SecTrustGetCertificateCount(trust);
            
            if certCount > 0 {
                let cert = SecTrustGetCertificateAtIndex(trust, 0);
                let fingerprint = Digest.sha1.digest(toHex: SecCertificateCopyData(cert!) as Data);
                let account = AccountManager.getAccount(forJid: sessionObject.userBareJid!.stringValue);
                valid = fingerprint == (account?.serverCertificate?["cert-hash-sha1"] as? String) && ((account?.serverCertificate?["accepted"] as? Bool) ?? false);
            }
            else {
                valid = false;
            }
        }
        return valid;
    }
    
    fileprivate class EventHandlerHolder {
        let handler:EventHandler;
        let events:[Event];
        
        init(handler: EventHandler, events: [Event]) {
            self.handler = handler;
            self.events = events;
        }
        
        func matches(_ handler: EventHandler, events: [Event]) -> Bool {
            return self.handler === handler && self.events == events;
        }
    }
    
    public enum ApplicationState {
        case active
        case inactive
    }
}

extension XMPPClient {
    
    var  pushNotificationsEnabled: Bool {
        let pushNotificationModule: TigasePushNotificationsModule? = self.modulesManager.getModule(TigasePushNotificationsModule.ID);
        return pushNotificationModule?.enabled ?? false;
    }
    
}