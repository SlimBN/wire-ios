//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import UIKit
import Social
import WireShareEngine
import Cartography
import MobileCoreServices
import ZMCDataModel
import WireExtensionComponents
import Classy

/// The delay after which a progess view controller will be displayed if all messages are not yet sent.
private let progressDisplayDelay: TimeInterval = 0.5


class ShareViewController: SLComposeServiceViewController {
    
    var conversationItem : SLComposeSheetConfigurationItem?
    var selectedConversation : Conversation?

    fileprivate var sharingSession: SharingSession? = nil
    fileprivate var sendController: SendController?

    private var observer: SendableBatchObserver? = nil
    private weak var progressViewController: SendingProgressViewController? = nil
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.setupNavigationBar()
        self.appendTextToEditor()
        self.placeholder = "share_extension.input.placeholder".localized
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    private func setupNavigationBar() {
        guard let item = navigationController?.navigationBar.items?.first else { return }
        item.rightBarButtonItem?.action = #selector(appendPostTapped)
        item.rightBarButtonItem?.title = "share_extension.send_button.title".localized
        item.titleView = UIImageView(image: UIImage(forLogoWith: .black, iconSize: .small))
    }

    deinit {
        sharingSession = nil
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.view.backgroundColor = .white
        recreateSharingSession()
    }
    
    override func presentationAnimationDidFinish() {
        guard let sharingSession = sharingSession, sharingSession.canShare else {
            return presentNotSignedInMessage()
        }
    }

    private func recreateSharingSession() {
        let infoDict = Bundle.main.infoDictionary

        guard let applicationGroupIdentifier = infoDict?["ApplicationGroupIdentifier"] as? String,
            let hostBundleIdentifier = infoDict?["HostBundleIdentifier"] as? String else { return }

        sharingSession = try? SharingSession(
            applicationGroupIdentifier: applicationGroupIdentifier,
            hostBundleIdentifier: hostBundleIdentifier
        )
    }

    override func isContentValid() -> Bool {
        // Do validation of contentText and/or NSExtensionContext attachments here
        return sharingSession != nil && selectedConversation != nil
    }

    /// invoked when the user wants to post
    func appendPostTapped() {
        guard let session = sharingSession, let conversation = selectedConversation else { return }
        let sendController = SendController(text: contentText, attachments: attachments, conversation: conversation, sharingSession: session)

        navigationController?.navigationBar.items?.first?.rightBarButtonItem?.isEnabled = false

        sendController.send { [weak self] progress in
            switch progress {
            case .preparing:
                DispatchQueue.main.asyncAfter(deadline: .now() + progressDisplayDelay) {
                    if sendController.sentAllSendables || nil != self?.progressViewController {
                        return
                    }
                    self?.presentSendingProgress(mode: .preparing)
                }

            case .prepared:
                DispatchQueue.main.asyncAfter(deadline: .now() + progressDisplayDelay) {
                    guard !sendController.sentAllSendables && nil == self?.progressViewController else { return }
                    self?.presentSendingProgress(mode: .sending)
                }

            case .sending(let progress):
                self?.progressViewController?.progress = progress

            case .done:
                UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: {
                    self?.view.alpha = 0
                    self?.navigationController?.view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                }, completion: { _ in
                    self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                })
            }
        }

        self.sendController = sendController
    }
    
    /// Display a preview image
    override func loadPreviewView() -> UIView! {
        if let parentView = super.loadPreviewView() {
            return parentView
        }
        let hasURL = self.attachments.first(where: { $0.hasItemConformingToTypeIdentifier(kUTTypeURL as String) }) != nil
        let hasEmptyText = self.textView.text.isEmpty
        // I can not ask if it's a http:// or file://, because it's an async operation, so I rely on the fact that 
        // if it has no image, it has a URL and it has text, it must be a file
        if  hasURL && hasEmptyText {
            return UIImageView(image: UIImage(for: .document, iconSize: .large, color: UIColor.black))
        }
        return nil
    }

    /// If there is a URL attachment, copy the text of the URL attachment into the text field
    private func appendTextToEditor() {
        self.fetchURLAttachments { [weak self] (urls) in
            guard let url = urls.first, let `self` = self else { return }
            DispatchQueue.main.async {
                if !url.isFileURL { // remote URL (not local file)
                    let separator = self.textView.text.isEmpty ? "" : "\n"
                    self.textView.text = self.textView.text + separator + url.absoluteString
                    self.textView.delegate?.textViewDidChange?(self.textView)
                }
                
            }
        }
    }
    
    override func configurationItems() -> [Any]! {
        let conversationItem = SLComposeSheetConfigurationItem()!
        self.conversationItem = conversationItem
        
        conversationItem.title = "share_extension.conversation_selection.title".localized
        conversationItem.value = "share_extension.conversation_selection.empty.value".localized
        conversationItem.tapHandler = { [weak self] in
             self?.presentChooseConversation()
        }
        
        return [conversationItem]
    }
    
    private func presentSendingProgress(mode: SendingProgressViewController.ProgressMode) {
        let progressSendingViewController = SendingProgressViewController()
        progressViewController?.mode = mode

        progressSendingViewController.cancelHandler = { [weak self] in
            self?.sendController?.cancel {
                self?.cancel()
            }
        }

        progressViewController = progressSendingViewController
        pushConfigurationViewController(progressSendingViewController)
    }
    
    private func presentNotSignedInMessage() {
        let notSignedInViewController = NotSignedInViewController()
        
        notSignedInViewController.closeHandler = { [weak self] in
            self?.cancel()
        }
        
        pushConfigurationViewController(notSignedInViewController)
    }
    
    private func presentChooseConversation() {
        guard let sharingSession = sharingSession else { return }

        let allConversations = sharingSession.writeableNonArchivedConversations + sharingSession.writebleArchivedConversations
        let conversationSelectionViewController = ConversationSelectionViewController(conversations: allConversations)
        
        conversationSelectionViewController.selectionHandler = { [weak self] conversation in
            self?.conversationItem?.value = conversation.name
            self?.selectedConversation = conversation
            self?.popConfigurationViewController()
            self?.validateContent()
        }
        
        pushConfigurationViewController(conversationSelectionViewController)
    }
}
