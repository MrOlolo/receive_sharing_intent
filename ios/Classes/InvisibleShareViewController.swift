import MobileCoreServices
import Photos
import UIKit

@objc(InvisibleShareViewController)
@available(swift, introduced: 5.0)
open class InvisibleShareViewController: UIViewController {
    var hostAppBundleIdentifier = ""
    var appGroupId = ""
    var sharedMedia: [SharedMediaFile] = []

    open override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .clear
        self.preferredContentSize = CGSize(
            width: UIScreen.main.bounds.width,
            height: UIScreen.main.bounds.height)

        loadIds()
        fetchContent()
    }

    private func loadIds() {
        // loading Share extension App Id
        let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier!

        // extract host app bundle id from ShareExtension id
        // by default it's <hostAppBundleIdentifier>.<ShareExtension>
        // for example: "com.kasem.sharing.Share-Extension" -> com.kasem.sharing
        let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(
            of: ".")
        hostAppBundleIdentifier = String(
            shareExtensionAppBundleIdentifier[..<lastIndexOfPoint!])
        let defaultAppGroupId = "group.\(hostAppBundleIdentifier)"

        // loading custom AppGroupId from Build Settings or use group.<hostAppBundleIdentifier>
        let customAppGroupId =
            Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String

        appGroupId = customAppGroupId ?? defaultAppGroupId
    }

    func fetchContent() {
        if let content = extensionContext!.inputItems[0] as? NSExtensionItem {
            if let contents = content.attachments {
                for (index, attachment) in (contents).enumerated() {
                    for type in SharedMediaType.allCases {
                        if attachment.hasItemConformingToTypeIdentifier(
                            type.toUTTypeIdentifier)
                        {
                            attachment.loadItem(
                                forTypeIdentifier: type.toUTTypeIdentifier
                            ) { [weak self] data, error in
                                guard let this = self, error == nil else {
                                    self?.dismissWithError()
                                    return
                                }
                                switch type {
                                case .text:
                                    if let text = data as? String {
                                        this.handleMedia(
                                            forLiteral: text,
                                            type: type,
                                            index: index,
                                            content: content)
                                    }
                                case .url:
                                    if let url = data as? URL {
                                        this.handleMedia(
                                            forLiteral: url.absoluteString,
                                            type: type,
                                            index: index,
                                            content: content)
                                    }
                                default:
                                    if let url = data as? URL {
                                        this.handleMedia(
                                            forFile: url,
                                            type: type,
                                            index: index,
                                            content: content)
                                    } else if let image = data as? UIImage {
                                        this.handleMedia(
                                            forUIImage: image,
                                            type: type,
                                            index: index,
                                            content: content)
                                    }
                                }
                            }
                            break
                        }
                    }
                }
            }
        }
    }

    private func handleMedia(
        forLiteral item: String, type: SharedMediaType, index: Int,
        content: NSExtensionItem
    ) {
        sharedMedia.append(
            SharedMediaFile(
                path: item,
                mimeType: type == .text ? "text/plain" : nil,
                type: type
            ))

        if index == (content.attachments?.count ?? 0) - 1 {
            saveAndRedirect()
        }

    }

    private func handleMedia(
        forUIImage image: UIImage, type: SharedMediaType, index: Int,
        content: NSExtensionItem
    ) {
        let tempPath = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId)!
            .appendingPathComponent("TempImage.png")
        if self.writeTempFile(image, to: tempPath) {
            let newPathDecoded = tempPath.absoluteString
                .removingPercentEncoding!
            sharedMedia.append(
                SharedMediaFile(
                    path: newPathDecoded,
                    mimeType: type == .image ? "image/png" : nil,
                    type: type
                ))
        }

        if index == (content.attachments?.count ?? 0) - 1 {
            saveAndRedirect()
        }

    }

    private func handleMedia(
        forFile url: URL, type: SharedMediaType, index: Int,
        content: NSExtensionItem
    ) {
        let fileName = getFileName(from: url, type: type)
        let newPath = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId)!
            .appendingPathComponent(fileName)

        if copyFile(at: url, to: newPath) {
            // The path should be decoded because Flutter is not expecting url encoded file names
            let newPathDecoded = newPath.absoluteString.removingPercentEncoding!
            if type == .video {
                // Get video thumbnail and duration
                if let videoInfo = getVideoInfo(from: url) {
                    let thumbnailPathDecoded = videoInfo.thumbnail?
                        .removingPercentEncoding
                    sharedMedia.append(
                        SharedMediaFile(
                            path: newPathDecoded,
                            mimeType: url.mimeType(),
                            thumbnail: thumbnailPathDecoded,
                            duration: videoInfo.duration,
                            type: type
                        ))
                }
            } else {
                sharedMedia.append(
                    SharedMediaFile(
                        path: newPathDecoded,
                        mimeType: url.mimeType(),
                        type: type
                    ))
            }
        }

        if index == (content.attachments?.count ?? 0) - 1 {
            saveAndRedirect()
        }
    }

    // Save shared media and redirect to host app
    private func saveAndRedirect(message: String? = nil) {

        let userDefaults = UserDefaults(suiteName: appGroupId)
        userDefaults?.set(toData(data: sharedMedia), forKey: kUserDefaultsKey)
        userDefaults?.set(message, forKey: kUserDefaultsMessageKey)
        userDefaults?.synchronize()
        redirectToHostApp()
    }

    private func redirectToHostApp() {
        // ids may not loaded yet so we need loadIds here too
        loadIds()
        let url = URL(
            string: "\(kSchemePrefix)-\(hostAppBundleIdentifier):share")
        var responder = self as UIResponder?

        if #available(iOS 18.0, *) {
            while responder != nil {
                if let application = responder as? UIApplication {
                    application.open(url!, options: [:], completionHandler: nil)
                }
                responder = responder?.next
            }
        } else {
            let selectorOpenURL = sel_registerName("openURL:")

            while responder != nil {
                if (responder?.responds(to: selectorOpenURL))! {
                    _ = responder?.perform(selectorOpenURL, with: url)
                }
                responder = responder!.next
            }
        }

        extensionContext!.completeRequest(
            returningItems: [], completionHandler: nil)
    }

    private func dismissWithError() {
        print("[ERROR] Error loading data!")
        let alert = UIAlertController(
            title: "Error", message: "Error loading data",
            preferredStyle: .alert)

        let action = UIAlertAction(title: "Error", style: .cancel) { _ in
            self.dismiss(animated: true, completion: nil)
        }

        alert.addAction(action)
        present(alert, animated: true, completion: nil)
        extensionContext!.completeRequest(
            returningItems: [], completionHandler: nil)
    }

    private func getFileName(from url: URL, type: SharedMediaType) -> String {
        var name = url.lastPathComponent
        if name.isEmpty {
            switch type {
            case .image:
                name = UUID().uuidString + ".png"
            case .video:
                name = UUID().uuidString + ".mp4"
            case .text:
                name = UUID().uuidString + ".txt"
            default:
                name = UUID().uuidString
            }
        }
        return name
    }

    private func writeTempFile(_ image: UIImage, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            let pngData = image.pngData()
            try pngData?.write(to: dstURL)
            return true
        } catch (let error) {
            print("Cannot write to temp file: \(error)")
            return false
        }
    }

    private func copyFile(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        } catch (let error) {
            print("Cannot copy item at \(srcURL) to \(dstURL): \(error)")
            return false
        }
        return true
    }

    private func getVideoInfo(from url: URL) -> (
        thumbnail: String?, duration: Double
    )? {
        let asset = AVAsset(url: url)
        let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
        let thumbnailPath = getThumbnailPath(for: url)

        if FileManager.default.fileExists(atPath: thumbnailPath.path) {
            return (thumbnail: thumbnailPath.absoluteString, duration: duration)
        }

        var saved = false
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        //        let scale = UIScreen.main.scale
        assetImgGenerate.maximumSize = CGSize(width: 360, height: 360)
        do {
            let img = try assetImgGenerate.copyCGImage(
                at: CMTimeMakeWithSeconds(600, preferredTimescale: 1),
                actualTime: nil)
            try UIImage(cgImage: img).pngData()?.write(to: thumbnailPath)
            saved = true
        } catch {
            saved = false
        }

        return saved
            ? (thumbnail: thumbnailPath.absoluteString, duration: duration)
            : nil
    }

    private func getThumbnailPath(for url: URL) -> URL {
        let fileName = Data(url.lastPathComponent.utf8).base64EncodedString()
            .replacingOccurrences(of: "==", with: "")
        let path = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!
            .appendingPathComponent("\(fileName).jpg")
        return path
    }

    private func toData(data: [SharedMediaFile]) -> Data {
        let encodedData = try? JSONEncoder().encode(data)
        return encodedData!
    }
}
