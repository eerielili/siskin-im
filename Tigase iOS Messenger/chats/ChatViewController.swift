//
// ChatViewController.swift
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

class ChatViewController : BaseChatViewController, UITableViewDataSource, EventHandler, CachedViewControllerProtocol {
    
    var titleView: ChatTitleView!;
    
    let log: Logger = Logger();
    var scrollToIndexPath: IndexPath? = nil;
    
    var dataSource: ChatDataSource!;
    var cachedDataSource: CachedViewDataSourceProtocol {
        return dataSource as CachedViewDataSourceProtocol;
    }
    
    var refreshControl: UIRefreshControl!;
    var syncInProgress = false;
    
    override func viewDidLoad() {
        dataSource = ChatDataSource(controller: self);
        scrollDelegate = self;
        super.viewDidLoad()
        self.initialize();
        tableView.dataSource = self;
        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false
        
        // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
        // self.navigationItem.rightBarButtonItem = self.editButtonItem()
        
        let navBarHeight = self.navigationController!.navigationBar.frame.size.height;
        let width = CGFloat(220);

        titleView = ChatTitleView(width: width, height: navBarHeight);
        titleView.name = navigationItem.title;
        
        let buddyBtn = UIButton(type: .system);
        buddyBtn.frame = CGRect(x: 0, y: 0, width: width, height: navBarHeight);
        buddyBtn.addSubview(titleView);
        
        buddyBtn.addTarget(self, action: #selector(ChatViewController.showBuddyInfo), for: .touchDown);
        self.navigationItem.titleView = buddyBtn;

        self.refreshControl = UIRefreshControl();
        self.refreshControl?.addTarget(self, action: #selector(ChatViewController.refreshChatHistory), for: UIControlEvents.valueChanged);
        self.tableView.addSubview(refreshControl);
    }
    
    func showBuddyInfo(_ button: UIButton) {
        print("open buddy info!");
        let navigation = storyboard?.instantiateViewController(withIdentifier: "ContactViewNavigationController") as! UINavigationController;
        let contactView = navigation.visibleViewController as! ContactViewController;
        contactView.account = account;
        contactView.jid = jid.bareJid;
        navigation.title = self.navigationItem.title;
        self.showDetailViewController(navigation, sender: self);

    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated);
        NotificationCenter.default.addObserver(self, selector: #selector(ChatViewController.newMessage), name: DBChatHistoryStore.MESSAGE_NEW, object: nil);
        NotificationCenter.default.addObserver(self, selector: #selector(ChatViewController.avatarChanged), name: AvatarManager.AVATAR_CHANGED, object: nil);
        
        xmppService.registerEventHandler(self, for: PresenceModule.ContactPresenceChanged.TYPE);
        
        let presenceModule: PresenceModule? = xmppService.getClient(forJid: account)?.modulesManager.getModule(PresenceModule.ID);
        titleView.status = presenceModule?.presenceStore.getBestPresence(for: jid.bareJid);
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        NotificationCenter.default.removeObserver(self);
        super.viewDidDisappear(animated);
        
        xmppService.unregisterEventHandler(self, for: PresenceModule.ContactPresenceChanged.TYPE);
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    // MARK: - Table view data source
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1;
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if dataSource.numberOfMessages == 0 {
            let label = UILabel(frame: CGRect(x: 0, y:0, width: self.view.bounds.size.width, height: self.view.bounds.size.height));
            label.text = "No messages available. Pull up to refresh message history.";
            label.numberOfLines = 0;
            label.textAlignment = .center;
            label.transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0);
            label.sizeToFit();
            self.tableView.backgroundView = label;
        }
        return dataSource.numberOfMessages;
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = dataSource.getItem(for: indexPath);
        let incoming = (item.state % 2) == 0;
        let id = incoming ? "ChatTableViewCellIncoming" : "ChatTableViewCellOutgoing"
        let cell: ChatTableViewCell = tableView.dequeueReusableCell(withIdentifier: id, for: indexPath) as! ChatTableViewCell;
        cell.transform = cachedDataSource.inverted ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0) : CGAffineTransform.identity;
        cell.avatarView?.image = self.xmppService.avatarManager.getAvatar(for: self.jid.bareJid, account: self.account);
        cell.setMessageText(item.data);
        cell.setTimestamp(item.timestamp);
        cell.setNeedsUpdateConstraints();
        cell.updateConstraintsIfNeeded();
        return cell;
    }
    
    class ChatViewItem {
        let state: Int;
        let data: String?;
        let timestamp: Date;
        
        init(cursor: DBCursor) {
            state = cursor["state"]!;
            data = cursor["data"];
            timestamp = cursor["timestamp"]!;
        }
        
    }
    
    func handle(event: Event) {
        switch event {
        case let cpc as PresenceModule.ContactPresenceChanged:
            guard cpc.presence.from?.bareJid == self.jid.bareJid && cpc.sessionObject.userBareJid == account else {
                return;
            }
            
            DispatchQueue.main.async() {
                self.titleView.status = cpc.presence;
            }
        default:
            break;
        }
    }
    
    func newMessage(_ notification: NSNotification) {
        guard ((notification.userInfo?["account"] as? BareJID) == account) && ((notification.userInfo?["sender"] as? BareJID) == jid.bareJid) else {
            return;
        }
        
        guard notification.userInfo?["fromArchive"] as? Bool ?? false == false else {
            if !self.syncInProgress {
                cachedDataSource.reset();
                tableView.reloadData();
            }
            return;
        }
        
        self.newItemAdded();

        if let state = notification.userInfo?["state"] as? DBChatHistoryStore.State {
            if state == .incoming_unread {
                self.xmppService.dbChatHistoryStore.markAsRead(for: account, with: jid.bareJid);
            }
        }
    }
    
    func avatarChanged(_ notification: NSNotification) {
        guard ((notification.userInfo?["jid"] as? BareJID) == jid.bareJid) else {
            return;
        }
        if let indexPaths = tableView.indexPathsForVisibleRows {
            tableView.reloadRows(at: indexPaths, with: .none);
        }
    }
    
    @objc func refreshChatHistory() {
        let syncPeriod = AccountSettings.MessageSyncPeriod(account.stringValue).getDouble();
        guard syncPeriod != 0 else {
            self.refreshControl.endRefreshing();
            return;
        }

        let date = Date().addingTimeInterval(syncPeriod * -60.0 * 60);
        syncInProgress = true;
        syncHistory(start: date);
    }
    
    func syncHistory(start: Date, rsm rsmQuery: RSM.Query? = nil) {
        guard let mamModule: MessageArchiveManagementModule = self.xmppService.getClient(forJid: self.account)?.modulesManager.getModule(MessageArchiveManagementModule.ID) else {
            syncInProgress = false;
            self.refreshControl.endRefreshing();
            return;
        }
        
        mamModule.queryItems(with: jid, start: start, queryId: "sync-2", rsm: rsmQuery ?? RSM.Query(lastItems: 100), onSuccess: {(queryid,complete,rsmResponse) in
            self.log("received items from archive", queryid, complete, rsmResponse);
            if rsmResponse != nil && rsmResponse!.index != 0 && rsmResponse?.first != nil {
                self.syncHistory(start: start, rsm: rsmResponse?.previous(100));
            } else {
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.2) {
                    self.cachedDataSource.reset();
                    self.syncInProgress = false;
                    self.tableView.reloadData();
                    self.refreshControl.endRefreshing();
                }
            }
        }, onError: {(error,stanza) in
            self.log("failed to retrieve items from archive", error, stanza);
            DispatchQueue.main.async {
                self.cachedDataSource.reset();
                self.syncInProgress = false;
                self.tableView.reloadData();
                self.refreshControl.endRefreshing();
            }
        });
    }
    
    @IBAction func sendClicked(_ sender: UIButton) {
        let text = messageField.text;
        guard !(text?.isEmpty != false) else {
            return;
        }
        
        let client = xmppService.getClient(forJid: account);
        if client != nil && client!.state == .connected {
            DispatchQueue.global(qos: .default).async {
                let messageModule: MessageModule? = client?.modulesManager.getModule(MessageModule.ID);
                if let chat = messageModule?.chatManager.getChat(with: self.jid, thread: nil) {
                    let msg = messageModule!.sendMessage(in: chat, body: text!);
                    self.xmppService.dbChatHistoryStore.appendMessage(for: client!.sessionObject, message: msg);
                }
            }
            messageField.text = nil;
        } else {
            var alert: UIAlertController? = nil;
            if client == nil {
                alert = UIAlertController.init(title: "Warning", message: "Account is disabled.\nDo you want to enable account?", preferredStyle: .alert);
                alert?.addAction(UIAlertAction(title: "No", style: .cancel, handler: nil));
                alert?.addAction(UIAlertAction(title: "Yes", style: .default, handler: {(alertAction) in
                    if let account = AccountManager.getAccount(forJid: self.account.stringValue) {
                        account.active = true;
                        AccountManager.updateAccount(account);
                    }
                }));
            } else if client?.state != .connected {
                alert = UIAlertController.init(title: "Warning", message: "Account is disconnected.\nPlease wait until account will reconnect", preferredStyle: .alert);
                alert?.addAction(UIAlertAction(title: "OK", style: .default, handler: nil));
            }
            if alert != nil {
                self.present(alert!, animated: true, completion: nil);
            }
        }
    }
    
    class ChatDataSource: CachedViewDataSource<ChatViewItem> {
        
        fileprivate let getMessagesStmt: DBStatement!;
        
        weak var controller: ChatViewController?;
        
        init(controller: ChatViewController) {
            self.controller = controller;
            self.getMessagesStmt = controller.xmppService.dbChatHistoryStore.getMessagesStatementForAccountAndJid();
        }
        
        override func getItemsCount() -> Int {
            return controller!.xmppService.dbChatHistoryStore.countMessages(for: controller!.account, with: controller!.jid.bareJid);
        }
        
        override func loadData(offset: Int, limit: Int, forEveryItem: (ChatViewItem)->Void) {
            controller!.xmppService.dbChatHistoryStore.forEachMessage(stmt: getMessagesStmt, account: controller!.account, jid: controller!.jid.bareJid, limit: limit, offset: offset, forEach: { (cursor)-> Void in
                forEveryItem(ChatViewItem(cursor: cursor));
            });
        }
    }
    
    class ChatTitleView: UIView {
        
        let nameView: UILabel!;
        let statusView: UILabel!;
        let statusHeight: CGFloat!;
        
        var name: String? {
            get {
                return nameView.text;
            }
            set {
                nameView.text = newValue;
            }
        }
        
        var status: Presence? {
            didSet {
                let statusIcon = NSTextAttachment();
                statusIcon.image = AvatarStatusView.getStatusImage(status?.show);
                statusIcon.bounds = CGRect(x: 0, y: -3, width: statusHeight, height: statusHeight);
                var desc = status?.status;
                if desc == nil {
                    let show = status?.show;
                    if show == nil {
                        desc = "Offline";
                    } else {
                        switch(show!) {
                        case .online:
                            desc = "Online";
                        case .chat:
                            desc = "Free for chat";
                        case .away:
                            desc = "Be right back";
                        case .xa:
                            desc = "Away";
                        case .dnd:
                            desc = "Do not disturb";
                        }
                    }
                }
                let statusText = NSMutableAttributedString(attributedString: NSAttributedString(attachment: statusIcon));
                statusText.append(NSAttributedString(string: desc!));
                statusView.attributedText = statusText;
            }
        }
        
        init(width: CGFloat, height: CGFloat) {
            let spacing = (height * 0.23) / 3;
            statusHeight = height * 0.32;
            nameView = UILabel(frame: CGRect(x: 0, y: spacing, width: width, height: height * 0.48));
            statusView = UILabel(frame: CGRect(x: 0, y: (height * 0.44) + (spacing * 2), width: width, height: statusHeight));
            super.init(frame: CGRect(x: 0, y: 0, width: width, height: height));
            
            
            var font = nameView.font;
            font = font?.withSize((font?.pointSize)!);
            nameView.font = font;
            nameView.textAlignment = .center;
            nameView.adjustsFontSizeToFitWidth = true;
            
            font = statusView.font;
            font = font?.withSize((font?.pointSize)! - 5);
            statusView.font = font;
            statusView.textAlignment = .center;
            statusView.adjustsFontSizeToFitWidth = true;
            
            self.isUserInteractionEnabled = false;
            
            self.addSubview(nameView);
            self.addSubview(statusView);
        }
        
        required init?(coder aDecoder: NSCoder) {
            statusHeight = nil;
            statusView = nil;
            nameView = nil;
            super.init(coder: aDecoder);
        }
    }
}
