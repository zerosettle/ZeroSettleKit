import Foundation

/// Configuration for blockchain addresses and program IDs
/// Values are read from Info.plist which are populated from environment variables
public struct BlockchainConfig {

    // MARK: - Smart Contract Addresses

    /// Single Player Game Program ID (read from Info.plist SOLANA_PROGRAM_ID)
    public static let GAME_PROGRAM_ID: String = {
        Bundle.main.object(forInfoDictionaryKey: "SOLANA_PROGRAM_ID") as? String ?? "9Mo3uo8avEpFL8PE2FYzuT5WgwsFuvKi1FKBH68q65rp"
    }()

    /// Game Admin Public Key (read from Info.plist)
    /// The game admin is responsible for staking game liability and submitting results
    public static let GAME_ADMIN_ADDRESS: String = {
        Bundle.main.object(forInfoDictionaryKey: "GAME_ADMIN_ADDRESS") as? String ?? "11111111111111111111111111111111"
    }()

    // MARK: - Network Configuration

    /// Solana cluster (read from Info.plist SOLANA_CLUSTER)
    /// Values: "mainnet-beta" or "devnet"
    public static let SOLANA_CLUSTER: String = {
        Bundle.main.object(forInfoDictionaryKey: "SOLANA_CLUSTER") as? String ?? "devnet"
    }()

    // MARK: - Token Addresses

    /// USDC/Token mint address (read from Info.plist USDC_MINT)
    /// IMPORTANT: This MUST match backend USDC_MINT environment variable
    public static let USDC_MINT: String = {
        Bundle.main.object(forInfoDictionaryKey: "USDC_MINT") as? String ?? "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
    }()

    // MARK: - Anchor Instruction Discriminators

    /// Discriminator for the PlayerStake instruction
    /// Calculated by Anchor from hash("global:player_stake")[0..8]
    /// Used to identify the player_stake instruction when building transactions
    public static let PLAYER_STAKE_DISCRIMINATOR: [UInt8] = [215, 244, 20, 129, 13, 245, 116, 150]

    // MARK: - Helper Methods

    /// Get the token mint address based on network environment
    /// - Mainnet: EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v (Official Circle USDC)
    /// - Devnet: Gh9ZwEmdLJ8DscKNTkTqPbNwLNNBjuSzaG9Vp2KGtKJr (Testnet USDC)
    public static func getUSDCMint(for environment: NetworkEnvironment) -> String {
        switch environment {
        case .mainnet:
            return "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"  // Official Circle USDC on mainnet
        case .devnet:
            //            return "Gh9ZwEmdLJ8DscKNTkTqPbNwLNNBjuSzaG9Vp2KGtKJr"  // Testnet USDC
            return "2KFZBjCnrxmkVdxg6m23d4WwofwBjjmPuoVYhNPhh698" // Local mint for USDC validation
        }
    }

    /// Get RPC endpoint based on SOLANA_CLUSTER
    public static func getRpcEndpoint() -> String {
        return SOLANA_CLUSTER == "mainnet-beta"
        ? "https://api.mainnet-beta.solana.com"
        : "https://api.devnet.solana.com"
    }

    // MARK: - Validation

    /// Check if placeholder addresses are still being used
    public static func isUsingPlaceholders() -> Bool {
        return GAME_PROGRAM_ID == "11111111111111111111111111111111" ||
        GAME_ADMIN_ADDRESS == "11111111111111111111111111111111" ||
        PLAYER_STAKE_DISCRIMINATOR == [0, 0, 0, 0, 0, 0, 0, 0]
    }

    /// Get a warning message if placeholders are still in use
    public static func getPlaceholderWarning() -> String? {
        if isUsingPlaceholders() {
            return """
            WARNING: Using placeholder blockchain addresses!
            Update BlockchainConfig.swift with your deployed contract addresses:
            - GAME_PROGRAM_ID
            - GAME_ADMIN_ADDRESS
            - PLAYER_STAKE_DISCRIMINATOR
            """
        }
        return nil
    }
}

// MARK: - Instructions for Updating

/*

 HOW TO UPDATE AFTER DEPLOYING YOUR SMART CONTRACT:

 1. Deploy your smart contract:
 cd smartcontracts/single_player_game
 anchor build
 anchor deploy --provider.cluster devnet

 2. Copy the Program ID from the deployment output

 3. Update GAME_PROGRAM_ID above with your program ID

 4. Update GAME_ADMIN_ADDRESS with your admin wallet public key

 5. Calculate the discriminator:
 - The discriminator is the first 8 bytes of sha256("global:player_stake")
 - You can find it in the generated IDL file: target/idl/single_player_game.json
 - Or use: echo -n "global:player_stake" | shasum -a 256 | cut -c1-16
 - Convert hex to bytes array: [0xAB, 0xCD, 0xEF, ...]

 6. Update PLAYER_STAKE_DISCRIMINATOR with the calculated bytes

 Example after deployment:

 public static let GAME_PROGRAM_ID = "DjZ9v3K8dLqR7nM2fT1pW8xY4sQ6hN3cU5bV7aE1mF9"
 public static let GAME_ADMIN_ADDRESS = "AdM1nK3yP2bL4cC8dR9eS6fT7gU8hV1iW2jX3kY4lZ5"
 public static let PLAYER_STAKE_DISCRIMINATOR: [UInt8] = [0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90]

 */
