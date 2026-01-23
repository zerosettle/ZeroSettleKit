import Foundation

final class PayoutTableService {
    private let config: ZeroSettleConfig
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    init(
        config: ZeroSettleConfig,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
    }

    func fetchLatestPayoutTable() async throws -> ZeroSettlePayoutTable {
        guard config.partnerAppId > 0 else {
            throw ZeroSettlePayoutError.invalidAppId
        }

        let token = config.partnerAuthTokenProvider?()

        let endpoint = config.apiBaseURL
            .appendingPathComponent("apps")
            .appendingPathComponent("\(config.partnerAppId)")
            .appendingPathComponent("payout-table")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ZeroSettlePayoutError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 {
                    throw ZeroSettlePayoutError.unauthorized
                }

                let serverMessage = try? decoder.decode(ServerErrorResponse.self, from: data).error
                throw ZeroSettlePayoutError.serverError(
                    code: httpResponse.statusCode,
                    message: serverMessage
                )
            }

            let payload = try decoder.decode(PartnerPayoutResponse.self, from: data)

            return payload.payoutTable.toDomainModel { guesses in
                descriptionForGuesses(guesses)
            }
        } catch let error as ZeroSettlePayoutError {
            throw error
        } catch let decodingError as DecodingError {
            throw ZeroSettlePayoutError.decodingFailed(decodingError)
        } catch {
            throw ZeroSettlePayoutError.transportError(error)
        }
    }

    private func descriptionForGuesses(_ guessesUsed: Int) -> String? {
        switch guessesUsed {
        case 1: return "Jackpot"
        case 2: return "Lightning fast"
        case 3: return "Quick solve"
        case 4: return "Solid win"
        case 5: return "Clutch finish"
        case 6: return "Last chance"
        default: return nil
        }
    }
}

// MARK: - Errors

public enum ZeroSettlePayoutError: Error, LocalizedError {
    case invalidAppId
    case unauthorized
    case invalidResponse
    case serverError(code: Int, message: String?)
    case decodingFailed(DecodingError)
    case transportError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidAppId:
            return "ZeroSettle partner app ID is not configured."
        case .unauthorized:
            return "Unauthorized to fetch payout table. Provide a valid partner session token."
        case .invalidResponse:
            return "Received an invalid response from the ZeroSettle API."
        case .serverError(let code, let message):
            return message ?? "Server returned status code \(code)."
        case .decodingFailed(let error):
            return "Failed to decode payout table: \(error.localizedDescription)"
        case .transportError(let error):
            return "Network error while fetching payout table: \(error.localizedDescription)"
        }
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String?
}

