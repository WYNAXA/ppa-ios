import UIKit
import WebKit
import AuthenticationServices
import SafariServices


func createWebView(container: UIView, WKSMH: WKScriptMessageHandler, WKND: WKNavigationDelegate, NSO: NSObject, VC: ViewController) -> WKWebView{

    let config = WKWebViewConfiguration()
    let userContentController = WKUserContentController()

    userContentController.add(WKSMH, name: "print")
    userContentController.add(WKSMH, name: "push-subscribe")
    userContentController.add(WKSMH, name: "push-permission-request")
    userContentController.add(WKSMH, name: "push-permission-state")
    userContentController.add(WKSMH, name: "push-token")
    userContentController.add(WKSMH, name: "onesignal")

    config.userContentController = userContentController

    config.limitsNavigationsToAppBoundDomains = true;
    config.allowsInlineMediaPlayback = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.preferences.setValue(true, forKey: "standalone")
    
    let webView = WKWebView(frame: calcWebviewFrame(webviewView: container, toolbarView: nil), configuration: config)
    setCustomCookie(webView: webView)

    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isHidden = true;
    webView.navigationDelegate = WKND
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.allowsBackForwardNavigationGestures = true
    
    // Check if macCatalyst 16.4+ is available and if so, enable web inspector.
    // This allows the web app to be inspected using Safari Web Inspector. Supported on iOS 16.4+ and macOS 13.3+
    if #available(iOS 16.4, macOS 13.3, *) {
        webView.isInspectable = true
    }
    
    let deviceModel = UIDevice.current.model
    let osVersion = UIDevice.current.systemVersion
    webView.configuration.applicationNameForUserAgent = "Safari/604.1"
    webView.customUserAgent = "Mozilla/5.0 (\(deviceModel); CPU \(deviceModel) OS \(osVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Mobile/15E148 Safari/604.1 PWAShell"

    webView.addObserver(NSO, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: NSKeyValueObservingOptions.new, context: nil)
    
    #if DEBUG
    if #available(iOS 16.4, *) {
        webView.isInspectable = true
    }
    #endif
    
    return webView
}

func setAppStoreAsReferrer(contentController: WKUserContentController) {
    let scriptSource = "document.referrer = `app-info://platform/ios-store`;"
    let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    contentController.addUserScript(script);
}

func setCustomCookie(webView: WKWebView) {
    let _platformCookie = HTTPCookie(properties: [
        .domain: rootUrl.host!,
        .path: "/",
        .name: platformCookie.name,
        .value: platformCookie.value,
        .secure: "FALSE",
        .expires: NSDate(timeIntervalSinceNow: 31556926)
    ])!

    webView.configuration.websiteDataStore.httpCookieStore.setCookie(_platformCookie)

}

func calcWebviewFrame(webviewView: UIView, toolbarView: UIToolbar?) -> CGRect{
    if ((toolbarView) != nil) {
        return CGRect(x: 0, y: toolbarView!.frame.height, width: webviewView.frame.width, height: webviewView.frame.height - toolbarView!.frame.height)
    }
    else {
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 0

        switch displayMode {
        case "fullscreen":
            #if targetEnvironment(macCatalyst)
                if let titlebar = windowScene.titlebar {
                    titlebar.titleVisibility = .hidden
                    titlebar.toolbar = nil
                }
            #endif
            return CGRect(x: 0, y: 0, width: webviewView.frame.width, height: webviewView.frame.height)
        default:
            #if targetEnvironment(macCatalyst)
            statusBarHeight = 29
            #endif
            let windowHeight = webviewView.frame.height - statusBarHeight
            return CGRect(x: 0, y: statusBarHeight, width: webviewView.frame.width, height: windowHeight)
        }
    }
}

extension ViewController: WKUIDelegate, WKDownloadDelegate {
    // redirect new tabs to main webview — but only for same-origin URLs.
    // External URLs open in SFSafariViewController instead of polluting the main webview.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            if let url = navigationAction.request.url, let host = url.host {
                let isSameOrigin = allowedOrigins.contains(where: { host.range(of: $0) != nil })
                    || authOrigins.contains(where: { host.range(of: $0) != nil })
                if isSameOrigin {
                    webView.load(navigationAction.request)
                } else if ["http", "https"].contains(url.scheme?.lowercased()) {
                    let safari = SFSafariViewController(url: url)
                    self.present(safari, animated: true, completion: nil)
                } else if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                }
            } else if let url = navigationAction.request.url {
                // No host (data:, blob:, tel:, mailto:) — hand to the OS
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                }
            }
        }
        return nil
    }

    // restrict navigation to target host, open external links in 3rd party apps
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // about: (blank frames, etc.) — allow
        if navigationAction.request.url?.scheme == "about" {
            return decisionHandler(.allow)
        }

        // Blob downloads — hand to the download delegate
        if navigationAction.shouldPerformDownload || navigationAction.request.url?.scheme == "blob" {
            return decisionHandler(.download)
        }

        guard let requestUrl = navigationAction.request.url else {
            return decisionHandler(.cancel)
        }

        let scheme = requestUrl.scheme?.lowercased() ?? ""

        // ── Scheme-first handling (before host check) ─────────────────────────
        // data: URIs have no host. Calendar data URIs must be written to a temp
        // file so iOS can hand them to the Calendar app.
        if scheme == "data" {
            decisionHandler(.cancel)
            handleDataUri(requestUrl)
            return
        }

        // tel: / mailto: — hand to the OS
        if scheme == "tel" || scheme == "mailto" {
            decisionHandler(.cancel)
            if UIApplication.shared.canOpenURL(requestUrl) {
                UIApplication.shared.open(requestUrl)
            }
            return
        }

        // File URLs
        if requestUrl.isFileURL {
            decisionHandler(.cancel)
            downloadAndOpenFile(url: requestUrl.absoluteURL)
            return
        }

        // ── Host-based routing (http/https) ───────────────────────────────────
        guard let requestHost = requestUrl.host else {
            return decisionHandler(.cancel)
        }

        // Auth origins (e.g. OAuth providers) — load in-app with toolbar
        let matchingAuthOrigin = authOrigins.first(where: { requestHost.range(of: $0) != nil })
        if matchingAuthOrigin != nil {
            decisionHandler(.allow)
            if toolbarView.isHidden {
                toolbarView.isHidden = false
                webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: toolbarView)
            }
            return
        }

        // Allowed (same) origins — load in main webview, hide toolbar
        let matchingHostOrigin = allowedOrigins.first(where: { requestHost.range(of: $0) != nil })
        if matchingHostOrigin != nil {
            decisionHandler(.allow)
            if !toolbarView.isHidden {
                toolbarView.isHidden = true
                webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
            }
            return
        }

        // Sub-resource loads (iframes, XHR redirects) — allow if they look like
        // in-page navigations rather than user clicks.  Safe optional read of
        // the private syntheticClickType key (BUG 3 fix: was force-unwrapped).
        if navigationAction.navigationType == .other {
            let syntheticClickType = navigationAction.value(forKey: "syntheticClickType") as? Int ?? -1
            if syntheticClickType == 0
                && navigationAction.targetFrame != nil
                && navigationAction.sourceFrame != nil {
                return decisionHandler(.allow)
            }
        }

        // External URL — cancel in-app navigation, open in SFSafariViewController
        decisionHandler(.cancel)
        if ["http", "https"].contains(scheme) {
            let safariViewController = SFSafariViewController(url: requestUrl)
            self.present(safariViewController, animated: true, completion: nil)
        } else if UIApplication.shared.canOpenURL(requestUrl) {
            UIApplication.shared.open(requestUrl)
        }
    }

    /// Handle a data: URI by writing its payload to a temp file and presenting
    /// it via UIDocumentInteractionController (triggers iOS "Add to Calendar"
    /// for text/calendar content).
    private func handleDataUri(_ url: URL) {
        let str = url.absoluteString
        // Parse: data:[<mediatype>][;base64],<data>
        guard let commaIndex = str.firstIndex(of: ",") else { return }
        let header = String(str[str.index(str.startIndex, offsetBy: 5)..<commaIndex]) // skip "data:"
        let payload = String(str[str.index(after: commaIndex)...])

        let isBase64 = header.hasSuffix(";base64")
        let mimeType = header.replacingOccurrences(of: ";base64", with: "")
            .components(separatedBy: ";").first ?? "application/octet-stream"

        // Determine file extension from MIME
        let ext: String
        switch mimeType {
        case "text/calendar": ext = "ics"
        case "text/csv":      ext = "csv"
        case "application/pdf": ext = "pdf"
        default: ext = "bin"
        }

        // Decode payload
        let data: Data?
        if isBase64 {
            data = Data(base64Encoded: payload)
        } else if let decoded = payload.removingPercentEncoding {
            data = decoded.data(using: .utf8)
        } else {
            data = payload.data(using: .utf8)
        }
        guard let fileData = data else { return }

        // Write to temp file and present
        let tempDir = FileManager.default.temporaryDirectory
        let fileUrl = tempDir.appendingPathComponent("ppa-download.\(ext)")
        try? FileManager.default.removeItem(at: fileUrl)
        do {
            try fileData.write(to: fileUrl)
            DispatchQueue.main.async {
                self.openFile(url: fileUrl)
            }
        } catch {
            print("handleDataUri: failed to write temp file: \(error)")
        }
    }
    // Handle javascript: `window.alert(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler()
            }
        )
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.confirm(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(false)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler(true)
            }
        )
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.prompt(prompt: String, defaultText: String?)`
    func webView(_ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: prompt,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(nil)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler with Alert input
                if let input = alert.textFields?.first?.text {
                    completionHandler(input)
                }
            }
        )

        alert.addTextField { textField in
            textField.placeholder = defaultText
        }
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }

    func downloadAndOpenFile(url: URL){

        let destinationFileUrl = url
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig)
        let request = URLRequest(url:url)
        let task = session.downloadTask(with: request) { (tempLocalUrl, response, error) in
            if let tempLocalUrl = tempLocalUrl, error == nil {
                if let statusCode = (response as? HTTPURLResponse)?.statusCode {
                    print("Successfully download. Status code: \(statusCode)")
                }
                do {
                    try FileManager.default.copyItem(at: tempLocalUrl, to: destinationFileUrl)
                    self.openFile(url: destinationFileUrl)
                } catch (let writeError) {
                    print("Error creating a file \(destinationFileUrl) : \(writeError)")
                }
            } else {
                print("Error took place while downloading a file. Error description: \(error?.localizedDescription ?? "N/A") ")
            }
        }
        task.resume()
    }

    // func downloadAndOpenBase64File(base64String: String) {
    //     // Split the base64 string to extract the data and the file extension
    //     let components = base64String.components(separatedBy: ";base64,")

    //     // Make sure the base64 string has the correct format
    //     guard components.count == 2, let format = components.first?.split(separator: "/").last else {
    //         print("Invalid base64 string format")
    //         return
    //     }

    //     // Remove the data type prefix to get the base64 data
    //     let dataString = components.last!

    //     if let imageData = Data(base64Encoded: dataString) {
    //         let documentsUrl: URL  =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    //         let destinationFileUrl = documentsUrl.appendingPathComponent("image.\(format)")

    //         do {
    //             try imageData.write(to: destinationFileUrl)
    //             self.openFile(url: destinationFileUrl)
    //         } catch {
    //             print("Error writing image to file url: \(destinationFileUrl): \(error)")
    //         }
    //     }
    // }

    func openFile(url: URL) {
        self.documentController = UIDocumentInteractionController(url: url)
        self.documentController?.delegate = self
        self.documentController?.presentPreview(animated: true)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                suggestedFilename: String,
                completionHandler: @escaping (URL?) -> Void) {

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(suggestedFilename)

        // Remove existing file if it exists, otherwise it may show an old file/content just by having the same name.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        self.openFile(url: fileURL)
        completionHandler(fileURL)
    }
}
