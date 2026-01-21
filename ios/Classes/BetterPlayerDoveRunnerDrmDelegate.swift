import Foundation
import AVFoundation

public class BetterPlayerDoveRunnerDrmDelegate: NSObject, AVAssetResourceLoaderDelegate {
    public let certificateURL: URL
    public let licenseURL: URL?
    public let licenseHeaders: [String: String];

    private var assetId: String = ""
    private let defaultLicenseServerURL = URL(string: "https://drm-license.doverunner.com/ri/licenseManager.do")!

    public init(_ certificateURL: URL, withLicenseURL licenseURL: URL?, licenseHeaders headers: [String: String]) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.licenseHeaders = headers
        super.init()
    }

    private func getContentKeyAndLeaseExpiryFromKeyServerModule(request spc: Data) -> Data? {
        let finalLicenseURL = licenseURL ?? defaultLicenseServerURL
      
        var request = URLRequest(url: finalLicenseURL)
        request.httpMethod = "POST"
        for header in self.licenseHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        request.httpBody = spc
        
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            resultData = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        return resultData
    }

    private func getAppCertificate() throws -> Data {
        let rawData = try Data(contentsOf: certificateURL)
        if let decoded = Data(base64Encoded: rawData), !decoded.isEmpty {
            return decoded
        }

        return rawData
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let assetURI = loadingRequest.request.url else { return false }
        let urlString = assetURI.absoluteString
        let scheme = assetURI.scheme ?? ""
        guard scheme == "skd" else { return false }

        let certificate: Data
        do {
            certificate = try getAppCertificate()
        } catch {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorClientCertificateRejected))
            return true
        }

        let requestBytes: Data
        do {
            guard let contentIdData = urlString.data(using: .utf8) else {
                loadingRequest.finishLoading(with: nil)
                return true
            }
            requestBytes = try loadingRequest.streamingContentKeyRequestData(forApp: certificate, contentIdentifier: contentIdData, options: nil)
        } catch {
            loadingRequest.finishLoading(with: nil)
            return true
        }

        let spcString = "spc=" + requestBytes.base64EncodedString()
        guard let spcBody = spcString.data(using: .utf8) else {
            let error = NSError(
              domain: NSCocoaErrorDomain,
              code: CocoaError.Code.fileWriteInapplicableStringEncoding.rawValue,
              userInfo: [NSLocalizedDescriptionKey: "Failed to encode SPC body as UTF-8"]
            )
            loadingRequest.finishLoading(with: error)
            return true
        }
        let responseData = getContentKeyAndLeaseExpiryFromKeyServerModule(request: spcBody)

        if let responseData = responseData, !responseData.isEmpty {
            if let ckcData = Data(base64Encoded: responseData ) {
                loadingRequest.dataRequest?.respond(with: ckcData)
                loadingRequest.finishLoading()
            }
        } else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest) -> Bool {
        return self.resourceLoader(resourceLoader, shouldWaitForLoadingOfRequestedResource: renewalRequest)
    }
}
