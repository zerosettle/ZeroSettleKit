import Foundation
import WebKit

// MARK: - Event Names

public enum OnrampEventName: String {
    case loadPending = "onramp_api.load_pending"
    case loadSuccess = "onramp_api.load_success"
    case loadError = "onramp_api.load_error"
    case commitSuccess = "onramp_api.commit_success"
    case commitError = "onramp_api.commit_error"
    case cancel = "onramp_api.cancel"
    case pollingStart = "onramp_api.polling_start"
    case pollingSuccess = "onramp_api.polling_success"
    case pollingError = "onramp_api.polling_error"
    case event = "event" // Generic event wrapper
    case unknown
}

// MARK: - Error Codes

public enum OnrampErrorCode: String {
    case ERROR_CODE_INIT
    case ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED
    case ERROR_CODE_GUEST_APPLE_PAY_NOT_SETUP
    case ERROR_CODE_GUEST_CARD_SOFT_DECLINED
    case ERROR_CODE_GUEST_INVALID_CARD
    case ERROR_CODE_GUEST_CARD_INSUFFICIENT_BALANCE
    case ERROR_CODE_GUEST_CARD_HARD_DECLINED
    case ERROR_CODE_GUEST_CARD_RISK_DECLINED
    case ERROR_CODE_GUEST_REGION_MISMATCH
    case ERROR_CODE_GUEST_PERMISSION_DENIED
    case ERROR_CODE_GUEST_CARD_PREPAID_DECLINED
    case ERROR_CODE_GUEST_TRANSACTION_LIMIT
    case ERROR_CODE_GUEST_TRANSACTION_COUNT
    case ERROR_CODE_GUEST_TRANSACTION_BUY_FAILED
    case ERROR_CODE_GUEST_TRANSACTION_SEND_FAILED
    case ERROR_CODE_GUEST_TRANSACTION_TRANSACTION_FAILED
    case ERROR_CODE_GUEST_TRANSACTION_AVS_VALIDATION_FAILED
    case unknown
}

// MARK: - Event Model

public struct OnrampEvent: Decodable {
    public struct EventData: Decodable {
        public let errorCode: String?
        public let errorMessage: String?
        public let eventName: String?
        public let pageRoute: String?

        private enum CodingKeys: String, CodingKey {
            case errorCode
            case errorMessage
            case eventName
            case pageRoute
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
            errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            eventName = try container.decodeIfPresent(String.self, forKey: .eventName)
            pageRoute = try container.decodeIfPresent(String.self, forKey: .pageRoute)
        }
    }
    public let eventName: String
    public let data: EventData?
}

// MARK: - Message Handler

public final class OnrampListener: NSObject, WKScriptMessageHandler {
    public var onEvent: ((OnrampEventName, OnrampEvent.EventData?) -> Void)?

    public override init() {
        super.init()
#if DEBUG
        print("[Onramp] OnrampListener initialized")
#endif
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
#if DEBUG
        print("========================================")
        print("[Onramp] Message received: \(message.name)")
        print("[Onramp] Body: \(message.body)")
        print("========================================")
#endif

        guard message.name == "onramp" else {
#if DEBUG
            print("[Onramp] Unexpected message name: \(message.name)")
#endif
            return
        }

        do {
            // Convert message.body to Data
            let data: Data
            if let dict = message.body as? [String: Any] {
                data = try JSONSerialization.data(withJSONObject: dict, options: [])
            } else if let string = message.body as? String {
                guard let stringData = string.data(using: .utf8) else {
                    throw NSError(domain: "OnrampListener", code: -1)
                }
                data = stringData
            } else {
                data = try JSONSerialization.data(withJSONObject: message.body, options: [])
            }

            let event = try JSONDecoder().decode(OnrampEvent.self, from: data)
            let name = OnrampEventName(rawValue: event.eventName) ?? .unknown

#if DEBUG
            print("[Onramp] Event decoded: \(event.eventName)")
#endif

            onEvent?(name, event.data)
        } catch {
#if DEBUG
            print("[Onramp] Decode error: \(error)")
#endif
        }
    }

    /// Creates the JavaScript bridge that listens for Coinbase postMessage events
    public static func makeBridgeScript() -> WKUserScript {
        let js = """
        (function() {
          if (window.__onrampBridgeInstalled) return;
          window.__onrampBridgeInstalled = true;
        
          console.log('[Onramp Bridge] Installing message listener');
        
          window.addEventListener('message', function(event) {
            console.log('[Onramp Bridge] Event captured:', event.data);
        
            try {
              window.webkit?.messageHandlers?.onramp?.postMessage(event.data);
              console.log('[Onramp Bridge] Message forwarded to native');
            } catch (e) {
              console.error('[Onramp Bridge] Error forwarding message:', e);
            }
          }, false);
        
          console.log('[Onramp Bridge] Listener installed successfully');
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
