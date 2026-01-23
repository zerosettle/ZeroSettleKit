import Foundation
import Solana

/// Handles game staking smart contract interactions
public class GameStaking {

    // MARK: - Public Methods

    /// Stakes tokens for a game session using the PlayerStake smart contract instruction
    /// - Parameters:
    ///   - walletAddress: The player's wallet address
    ///   - gameSessionId: The game session UUID from the backend
    ///   - stakeAmountCents: The stake amount in cents (e.g., 300 for $3.00)
    ///   - maxPayoutMultiplier: The maximum payout multiplier from the payout table
    ///   - networkEnvironment: The network environment (mainnet/devnet)
    ///   - rpcEndpoint: The Solana RPC endpoint to use
    ///   - feePayerAddress: Optional backend fee payer address (for relayer pattern). If nil, player pays fees.
    /// - Returns: Base58-encoded serialized transaction ready to be signed
    public static func buildStakeTransaction(
        walletAddress: String,
        gameSessionId: String,
        stakeAmountCents: Int,
        maxPayoutMultiplier: Double,
        networkEnvironment: NetworkEnvironment,
        rpcEndpoint: String,
        feePayerAddress: String? = nil
    ) async throws -> String {

        print("[GameStaking] Building stake transaction...")
        print("   - Network: \(networkEnvironment.displayName)")
        print("   - Wallet: \(walletAddress)")
        print("   - Game Session ID: \(gameSessionId)")
        print("   - Stake: \(stakeAmountCents) cents ($\(String(format: "%.2f", Double(stakeAmountCents) / 100.0)))")
        print("   - Max Multiplier: \(maxPayoutMultiplier)x")

        // Check for placeholder addresses
        if let warning = BlockchainConfig.getPlaceholderWarning() {
            print("[GameStaking] \(warning)")
        }

        // Get addresses from config
        let programIdString = BlockchainConfig.GAME_PROGRAM_ID
        let gameAdminString = BlockchainConfig.GAME_ADMIN_ADDRESS
        let usdcMintString = BlockchainConfig.getUSDCMint(for: networkEnvironment)

        print("   - Program ID: \(programIdString)")
        print("   - Game Admin: \(gameAdminString)")
        print("   - USDC Mint: \(usdcMintString)")

        // Convert wallet address to PublicKey
        guard let playerPubkey = PublicKey(string: walletAddress) else {
            throw GameStakingError.invalidAddress("Invalid player wallet address")
        }

        // Convert program ID to PublicKey
        guard let programId = PublicKey(string: programIdString) else {
            throw GameStakingError.invalidAddress("Invalid program ID: \(programIdString)")
        }

        // Convert USDC mint to PublicKey
        guard let usdcMint = PublicKey(string: usdcMintString) else {
            throw GameStakingError.invalidAddress("Invalid USDC mint address: \(usdcMintString)")
        }

        // Convert game admin to PublicKey
        guard let gameAdminPubkey = PublicKey(string: gameAdminString) else {
            throw GameStakingError.invalidAddress("Invalid game admin address: \(gameAdminString)")
        }

        // Generate session ID from game session ID
        let sessionId = generateSessionId(from: gameSessionId)

        // Convert stake amount from cents to USDC base units (6 decimals)
        // $3.00 = 300 cents = 3,000,000 USDC base units
        let stakeAmount = UInt64(stakeAmountCents) * 10_000

        // Convert max multiplier to u64 (multiply by 100 to preserve 2 decimal places)
        // e.g., 10.0x becomes 1000
        let maxMultiplier = UInt64(maxPayoutMultiplier * 100)

        print("   - Session ID (bytes): \(sessionId.map { String(format: "%02x", $0) }.prefix(8).joined())...")
        print("   - Stake (USDC base units): \(stakeAmount)")
        print("   - Max Multiplier (encoded): \(maxMultiplier)")

        // Derive PDA addresses
        let gameSessionPDA = try deriveGameSessionPDA(
            programId: programId,
            player: playerPubkey,
            sessionId: sessionId
        )
        print("   - Game Session PDA: \(gameSessionPDA.base58EncodedString)")

        let escrowPDA = try deriveEscrowPDA(
            programId: programId,
            gameSession: gameSessionPDA
        )
        print("   - Escrow PDA: \(escrowPDA.base58EncodedString)")

        let escrowVaultPDA = try deriveEscrowVaultPDA(
            programId: programId,
            escrow: escrowPDA
        )
        print("   - Escrow Vault PDA: \(escrowVaultPDA.base58EncodedString)")

        // Derive player's USDC token account (ATA)
        let playerTokenAccount = try deriveAssociatedTokenAccount(
            wallet: playerPubkey,
            mint: usdcMint
        )
        print("   - Player Token Account: \(playerTokenAccount.base58EncodedString)")

        // Build instruction data
        let instructionData = buildPlayerStakeInstructionData(
            sessionId: sessionId,
            stake: stakeAmount,
            maxPayoutMultiplier: maxMultiplier
        )

        print("   - Instruction data: \(instructionData.map { String(format: "%02x", $0) }.joined())")

        // Build instruction with all required accounts
        let instruction = TransactionInstruction(
            keys: [
                // game_session - writable, not signer (will be created)
                AccountMeta(publicKey: gameSessionPDA, isSigner: false, isWritable: true),
                // escrow - writable, not signer (will be created)
                AccountMeta(publicKey: escrowPDA, isSigner: false, isWritable: true),
                // escrow_vault - writable, not signer (will be created)
                AccountMeta(publicKey: escrowVaultPDA, isSigner: false, isWritable: true),
                // mint - read-only, not signer
                AccountMeta(publicKey: usdcMint, isSigner: false, isWritable: false),
                // player - writable, signer (pays for account creation and provides tokens)
                AccountMeta(publicKey: playerPubkey, isSigner: true, isWritable: true),
                // player_token_account - writable, not signer
                AccountMeta(publicKey: playerTokenAccount, isSigner: false, isWritable: true),
                // game_admin - read-only, not signer
                AccountMeta(publicKey: gameAdminPubkey, isSigner: false, isWritable: false),
                // token_program - read-only, not signer
                AccountMeta(publicKey: .tokenProgramId, isSigner: false, isWritable: false),
                // system_program - read-only, not signer
                AccountMeta(publicKey: .systemProgramId, isSigner: false, isWritable: false),
            ],
            programId: programId,
            data: instructionData
        )

        print("   Instruction built with \(instruction.keys.count) accounts")

        // Fetch recent blockhash
        print("[GameStaking] Fetching recent blockhash...")
        guard let rpcURL = URL(string: rpcEndpoint) else {
            throw GameStakingError.invalidRPCEndpoint
        }

        let blockhash = try await fetchRecentBlockhash(rpcURL: rpcURL)
        print("   - Blockhash: \(blockhash)")

        // Determine fee payer (backend relayer or player)
        let feePayerPubkey: PublicKey
        if let feePayerString = feePayerAddress, let feePayer = PublicKey(string: feePayerString) {
            feePayerPubkey = feePayer
            print("[GameStaking] Using backend fee payer (relayer pattern)")
            print("   - Fee Payer: \(feePayerString)")
        } else {
            feePayerPubkey = playerPubkey
            print("[GameStaking] Player pays fees")
        }

        // Build transaction
        print("[GameStaking] Constructing transaction...")

        // Set up signatures: fee payer first, then player if different
        var signatures: [Transaction.Signature] = []
        if feePayerPubkey == playerPubkey {
            // Player is both fee payer and signer
            signatures = [Transaction.Signature(signature: nil, publicKey: playerPubkey)]
        } else {
            // Backend is fee payer, player is additional signer
            signatures = [
                Transaction.Signature(signature: nil, publicKey: feePayerPubkey),
                Transaction.Signature(signature: nil, publicKey: playerPubkey)
            ]
        }

        var transaction = Transaction(
            signatures: signatures,
            feePayer: feePayerPubkey,
            instructions: [instruction],
            recentBlockhash: blockhash
        )

        // Serialize transaction (unsigned)
        print("[GameStaking] Serializing transaction...")
        let serializeResult = transaction.serialize(requiredAllSignatures: false, verifySignatures: false)

        guard case .success(let serializedData) = serializeResult else {
            if case .failure(let error) = serializeResult {
                print("   Serialization failed: \(error)")
                throw error
            }
            throw GameStakingError.serializationFailed
        }

        let transactionBytes = [UInt8](serializedData)
        let transactionBase58 = Base58.encode(transactionBytes)

        print("[GameStaking] Stake transaction built successfully")
        print("   - Size: \(serializedData.count) bytes")
        print("   - Transaction (base58): \(String(transactionBase58.prefix(100)))...")

        return transactionBase58
    }

    // MARK: - Private Helpers

    /// Generates a 16-byte session ID from a UUID string
    private static func generateSessionId(from gameSessionId: String) -> [UInt8] {
        // Parse UUID string and convert to 16 bytes
        guard let uuid = UUID(uuidString: gameSessionId) else {
            fatalError("Invalid UUID string: \(gameSessionId)")
        }

        // Convert UUID to bytes (big-endian as per UUID spec)
        let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        return uuidBytes
    }

    /// Builds the instruction data for PlayerStake
    private static func buildPlayerStakeInstructionData(
        sessionId: [UInt8],
        stake: UInt64,
        maxPayoutMultiplier: UInt64
    ) -> [UInt8] {
        var data = [UInt8]()

        // Anchor discriminator (8 bytes) - hash of "global:player_stake"
        let discriminator = BlockchainConfig.PLAYER_STAKE_DISCRIMINATOR
        data.append(contentsOf: discriminator)

        // session_id: [u8; 32]
        data.append(contentsOf: sessionId)

        // stake: u64 (little-endian)
        let stakeBytes = withUnsafeBytes(of: stake.littleEndian) { Array($0) }
        data.append(contentsOf: stakeBytes)

        // max_payout_multiplier: u64 (little-endian)
        let multiplierBytes = withUnsafeBytes(of: maxPayoutMultiplier.littleEndian) { Array($0) }
        data.append(contentsOf: multiplierBytes)

        return data
    }

    /// Derives the game session PDA
    private static func deriveGameSessionPDA(
        programId: PublicKey,
        player: PublicKey,
        sessionId: [UInt8]
    ) throws -> PublicKey {
        let seeds: [Data] = [
            Data("game_session".utf8),
            player.data,
            Data(sessionId)
        ]

        let result = PublicKey.findProgramAddress(seeds: seeds, programId: programId)
        guard case .success(let pda) = result else {
            throw GameStakingError.pdaDerivationFailed("game_session")
        }

        return pda.0
    }

    /// Derives the escrow PDA
    private static func deriveEscrowPDA(
        programId: PublicKey,
        gameSession: PublicKey
    ) throws -> PublicKey {
        let seeds: [Data] = [
            Data("escrow".utf8),
            gameSession.data
        ]

        let result = PublicKey.findProgramAddress(seeds: seeds, programId: programId)
        guard case .success(let pda) = result else {
            throw GameStakingError.pdaDerivationFailed("escrow")
        }

        return pda.0
    }

    /// Derives the escrow vault PDA
    private static func deriveEscrowVaultPDA(
        programId: PublicKey,
        escrow: PublicKey
    ) throws -> PublicKey {
        let seeds: [Data] = [
            Data("escrow_vault".utf8),
            escrow.data
        ]

        let result = PublicKey.findProgramAddress(seeds: seeds, programId: programId)
        guard case .success(let pda) = result else {
            throw GameStakingError.pdaDerivationFailed("escrow_vault")
        }

        return pda.0
    }

    /// Derives the Associated Token Account address
    private static func deriveAssociatedTokenAccount(
        wallet: PublicKey,
        mint: PublicKey
    ) throws -> PublicKey {
        let result = PublicKey.associatedTokenAddress(
            walletAddress: wallet,
            tokenMintAddress: mint
        )

        guard case .success(let ata) = result else {
            throw GameStakingError.pdaDerivationFailed("associated_token_account")
        }

        return ata
    }

    /// Fetches a recent blockhash from the RPC
    private static func fetchRecentBlockhash(rpcURL: URL) async throws -> String {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getLatestBlockhash",
            "params": [
                ["commitment": "finalized"]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, _) = try await URLSession.shared.data(for: request)

        struct BlockhashResponse: Decodable {
            struct Result: Decodable {
                struct Value: Decodable {
                    let blockhash: String
                }
                let value: Value
            }
            let result: Result?
        }

        let response = try JSONDecoder().decode(BlockhashResponse.self, from: data)

        guard let blockhash = response.result?.value.blockhash else {
            throw GameStakingError.blockhashFetchFailed
        }

        return blockhash
    }
}

// MARK: - Errors

public enum GameStakingError: Error, LocalizedError {
    case invalidAddress(String)
    case pdaDerivationFailed(String)
    case invalidRPCEndpoint
    case blockhashFetchFailed
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let desc):
            return "Invalid address: \(desc)"
        case .pdaDerivationFailed(let pda):
            return "Failed to derive PDA: \(pda)"
        case .invalidRPCEndpoint:
            return "Invalid RPC endpoint"
        case .blockhashFetchFailed:
            return "Failed to fetch recent blockhash"
        case .serializationFailed:
            return "Failed to serialize transaction"
        }
    }
}
