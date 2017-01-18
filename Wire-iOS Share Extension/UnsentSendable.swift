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
import WireShareEngine
import MobileCoreServices
import WireExtensionComponents


enum UnsentSendableError: Error {
    case unsupportedAttachment
}


protocol UnsentSendableType {
    func prepare(completion: @escaping () -> Void)
    func send(completion: @escaping (Sendable?) -> Void)

    var needsPreparation: Bool { get }
    var error: UnsentSendableError? { get }
}


extension UnsentSendableType {
    func prepare(completion: @escaping () -> Void) {
        precondition(needsPreparation, "Ensure this objects needs preparation, c.f. `needsPreparation`")
    }
}


class UnsentSendableAbstract {

    let conversation: Conversation
    let sharingSession: SharingSession

    var needsPreparation = false

    var error: UnsentSendableError?

    init(conversation: Conversation, sharingSession: SharingSession) {
        self.conversation = conversation
        self.sharingSession = sharingSession
    }
}


class UnsentTextSendable: UnsentSendableAbstract, UnsentSendableType {

    private let text: String

    init(conversation: Conversation, sharingSession: SharingSession, text: String) {
        self.text = text
        super.init(conversation: conversation, sharingSession: sharingSession)
    }

    func send(completion: @escaping (Sendable?) -> Void) {
        sharingSession.enqueue {
            completion(self.conversation.appendTextMessage(self.text))
        }
    }

}


class UnsentImageSendable: UnsentSendableAbstract, UnsentSendableType {

    private let attachment: NSItemProvider
    private var imageData: Data?

    init?(conversation: Conversation, sharingSession: SharingSession, attachment: NSItemProvider) {
        guard attachment.hasItemConformingToTypeIdentifier(kUTTypeImage as String) else { return nil }
        self.attachment = attachment
        super.init(conversation: conversation, sharingSession: sharingSession)
        needsPreparation = true
    }

    func prepare(completion: @escaping () -> Void) {
        precondition(needsPreparation, "Ensure this objects needs preparation, c.f. `needsPreparation`")
        needsPreparation = false

        let options = [NSItemProviderPreferredImageSizeKey : NSValue(cgSize: .init(width: 1024, height: 1024))]

        attachment.loadItem(forTypeIdentifier: kUTTypeImage as String, options: options, imageCompletionHandler: { [weak self] (image, _) in
            self?.imageData = image.flatMap {
                UIImageJPEGRepresentation($0, 0.9)
            }

            completion()
        })
    }

    func send(completion: @escaping (Sendable?) -> Void) {
        sharingSession.enqueue {
            completion(self.imageData.flatMap(self.conversation.appendImage))
        }
    }

}


class UnsentFileSendable: UnsentSendableAbstract, UnsentSendableType {

    private let attachment: NSItemProvider
    private var metadata: ZMFileMetadata?
    private var fm = FileManager.default

    private let typeURL: Bool
    private let typeData: Bool

    init?(conversation: Conversation, sharingSession: SharingSession, attachment: NSItemProvider) {
        self.typeURL = attachment.hasItemConformingToTypeIdentifier(kUTTypeURL as String)
        self.typeData = attachment.hasItemConformingToTypeIdentifier(kUTTypeData as String)
        self.attachment = attachment
        super.init(conversation: conversation, sharingSession: sharingSession)
        guard typeURL || typeData else { return nil }
        needsPreparation = true
    }

    func prepare(completion: @escaping () -> Void) {
        precondition(needsPreparation, "Ensure this objects needs preparation, c.f. `needsPreparation`")
        needsPreparation = false

        if typeURL {
            attachment.fetchURL { [weak self] url in
                guard let `self` = self else { return }
                if (url != nil && !url!.isFileURL) || !self.typeData {
                    self.error = .unsupportedAttachment
                    return completion()
                }

                self.prepareAsFile(name: url?.lastPathComponent, completion: completion)
            }
        } else if typeData {
            prepareAsFile(name: nil, completion: completion)
        }
    }

    func send(completion: @escaping (Sendable?) -> Void) {
        sharingSession.enqueue {
            completion(self.metadata.flatMap(self.conversation.appendFile))
        }
    }

    private func prepareAsFile(name: String?, completion: @escaping () -> Void) {
        self.attachment.loadItem(forTypeIdentifier: kUTTypeData as String, options: [:], dataCompletionHandler: { (data, error) in
            guard let data = data, let UTIString = self.attachment.registeredTypeIdentifiers.first as? String, error == nil else {
                return completion()
            }

            self.prepareForSending(withUTI: UTIString, name: name, data: data) { (url, error) in
                guard let url = url, error == nil else { return completion() }

                FileMetaDataGenerator.metadataForFileAtURL(url, UTI: url.UTI(), name: name ?? url.lastPathComponent) { metadata -> Void in
                    self.metadata = metadata
                    completion()
                }
            }
        })
    }

    private func prepareForSending(withUTI UTI: String, name: String?, data: Data, completion: @escaping (URL?, Error?) -> Void) {
        guard let fileName = nameForFile(withUTI: UTI, name: name) else { return completion(nil, nil) }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString) // temp subdir

        do {
            if !fm.fileExists(atPath: tmp.absoluteString) {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            }
            let tempFileURL = tmp.appendingPathComponent(fileName)

            if fm.fileExists(atPath: tempFileURL.absoluteString) {
                try fm.removeItem(at: tempFileURL)
            }

            try data.write(to: tempFileURL)

            if UTTypeConformsTo(UTI as CFString, kUTTypeMovie) {
                AVAsset.wr_convertVideo(at: tempFileURL) { (url, _, error) in
                    completion(url, error)
                }
            } else {
                completion(tempFileURL, nil)
            }
        } catch {
            return completion(nil, error)
        }
    }


    private func nameForFile(withUTI UTI: String, name: String?) -> String? {
        if let fileExtension = UTTypeCopyPreferredTagWithClass(UTI as CFString, kUTTagClassFilenameExtension)?.takeRetainedValue() as? String {
            return "\(UUID().uuidString).\(fileExtension)"
        }
        return name
    }

}
