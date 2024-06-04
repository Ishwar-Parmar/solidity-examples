// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title PuppyRaffle
/// @notice This project is to enter a raffle to win a cute dog NFT.
contract PuppyRaffle is ERC721, Ownable, ReentrancyGuard {
    using Address for address payable;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public immutable entranceFee;
    uint256 public raffleDuration;
    uint256 public raffleStartTime;
    address public previousWinner;

    // We do some storage packing to save gas
    address public feeAddress;
    uint64 public totalFees;

    EnumerableSet.AddressSet private playersSet;

    // mappings to keep track of token traits
    mapping(uint256 => uint256) public tokenIdToRarity;
    mapping(uint256 => string) public rarityToUri;
    mapping(uint256 => string) public rarityToName;

    // Stats for the common puppy (pug)
    string private commonImageUri =
        "ipfs://QmSsYRx3LpDAb1GZQm7zZ1AuHZjfbPkD6J7s9r41xu1mf8";
    uint256 public constant COMMON_RARITY = 70;
    string private constant COMMON = "common";

    // Stats for the rare puppy (st. bernard)
    string private rareImageUri =
        "ipfs://QmUPjADFGEKmfohdTaNcWhp7VGk26h5jXDA7v3VtTnTLcW";
    uint256 public constant RARE_RARITY = 25;
    string private constant RARE = "rare";

    // Stats for the legendary puppy (shiba inu)
    string private legendaryImageUri =
        "ipfs://QmYx6GsYAKnNzZ9A6NvEKV9nf1VaDzJrqDR23Y8YSkebLU";
    uint256 public constant LEGENDARY_RARITY = 5;
    string private constant LEGENDARY = "legendary";

    // Events
    event RaffleEnter(address[] newPlayers);
    event RaffleRefunded(address player);
    event FeeAddressChanged(address newFeeAddress);
    event WinnerSelected(address winner);

    /// @param _entranceFee the cost in wei to enter the raffle
    /// @param _feeAddress the address to send the fees to
    /// @param _raffleDuration the duration in seconds of the raffle
    constructor(
        uint256 _entranceFee,
        address _feeAddress,
        uint256 _raffleDuration
    ) ERC721("Puppy Raffle", "PR") {
        entranceFee = _entranceFee;
        feeAddress = _feeAddress;
        raffleDuration = _raffleDuration;
        raffleStartTime = block.timestamp;

        rarityToUri[COMMON_RARITY] = commonImageUri;
        rarityToUri[RARE_RARITY] = rareImageUri;
        rarityToUri[LEGENDARY_RARITY] = legendaryImageUri;

        rarityToName[COMMON_RARITY] = COMMON;
        rarityToName[RARE_RARITY] = RARE;
        rarityToName[LEGENDARY_RARITY] = LEGENDARY;
    }

    /// @notice this is how players enter the raffle
    /// @notice they have to pay the entrance fee * the number of players
    /// @notice duplicate entrants are not allowed
    /// @param newPlayers the list of players to enter the raffle
    function enterRaffle(
        address[] memory newPlayers
    ) public payable nonReentrant {
        require(
            msg.value == entranceFee * newPlayers.length,
            "PuppyRaffle: Must send enough to enter raffle"
        );

        for (uint256 i = 0; i < newPlayers.length; i++) {
            require(
                playersSet.add(newPlayers[i]),
                "PuppyRaffle: Duplicate player"
            );
        }

        emit RaffleEnter(newPlayers);
    }

    /// @param playerIndex the index of the player to refund. You can find it externally by calling `getActivePlayerIndex`
    /// @dev This function will allow there to be blank spots in the array
    function refund(uint256 playerIndex) public nonReentrant {
        address playerAddress = playersSet.at(playerIndex);
        require(
            playerAddress == msg.sender,
            "PuppyRaffle: Only the player can refund"
        );

        playersSet.remove(playerAddress);
        payable(msg.sender).sendValue(entranceFee);

        emit RaffleRefunded(playerAddress);
    }

    /// @notice this function will return true if the msg.sender is an active player
    function _isActivePlayer() internal view returns (bool) {
        return playersSet.contains(msg.sender);
    }

    /// @notice this function will select a winner and mint a puppy
    /// @notice there must be at least 4 players, and the duration has occurred
    /// @notice the previous winner is stored in the previousWinner variable
    /// @dev we use a hash of on-chain data to generate the random numbers
    /// @dev we reset the active players set after the winner is selected
    /// @dev we send 80% of the funds to the winner, the other 20% goes to the feeAddress
    function selectWinner() external nonReentrant {
        require(
            block.timestamp >= raffleStartTime + raffleDuration,
            "PuppyRaffle: Raffle not over"
        );
        require(
            playersSet.length() >= 4,
            "PuppyRaffle: Need at least 4 players"
        );

        uint256 winnerIndex = uint256(
            keccak256(abi.encodePacked(block.timestamp, block.difficulty))
        ) % playersSet.length();
        address winner = playersSet.at(winnerIndex);

        uint256 totalAmountCollected = playersSet.length() * entranceFee;
        uint256 prizePool = (totalAmountCollected * 80) / 100;
        uint256 fee = (totalAmountCollected * 20) / 100;
        totalFees += uint64(fee);

        uint256 tokenId = totalSupply();

        // We use a different RNG calculation from the winnerIndex to determine rarity
        uint256 rarity = uint256(
            keccak256(abi.encodePacked(block.difficulty))
        ) % 100;
        if (rarity <= COMMON_RARITY) {
            tokenIdToRarity[tokenId] = COMMON_RARITY;
        } else if (rarity <= COMMON_RARITY + RARE_RARITY) {
            tokenIdToRarity[tokenId] = RARE_RARITY;
        } else {
            tokenIdToRarity[tokenId] = LEGENDARY_RARITY;
        }

        playersSet.clear();
        raffleStartTime = block.timestamp;
        previousWinner = winner;

        (bool success, ) = winner.call{value: prizePool}("");
        require(success, "PuppyRaffle: Failed to send prize pool to winner");

        _safeMint(winner, tokenId);

        emit WinnerSelected(winner);
    }

    /// @notice this function will withdraw the fees to the feeAddress
    function withdrawFees() external nonReentrant {
        uint256 feesToWithdraw = totalFees;
        totalFees = 0;
        (bool success, ) = feeAddress.call{value: feesToWithdraw}("");
        require(success, "PuppyRaffle: Failed to withdraw fees");
    }

    /// @notice only the owner of the contract can change the feeAddress
    /// @param newFeeAddress the new address to send fees to
    function changeFeeAddress(address newFeeAddress) external onlyOwner {
        feeAddress = newFeeAddress;
        emit FeeAddressChanged(newFeeAddress);
    }

    /// @notice this function will return the URI for the token
    /// @param tokenId the Id of the NFT
    function tokenURI(
        uint256 tokenId
    ) public view virtual override returns (string memory) {
        require(
            _exists(tokenId),
            "PuppyRaffle: URI query for nonexistent token"
        );

        uint256 rarity = tokenIdToRarity[tokenId];
        string memory imageURI = rarityToUri[rarity];
        string memory rareName = rarityToName[rarity];

        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(
                        bytes(
                            abi.encodePacked(
                                '{"name":"',
                                name(),
                                '", "description":"An adorable puppy!", ',
                                '"attributes": [{"trait_type": "rarity", "value": "',
                                rareName,
                                '"}], "image":"',
                                imageURI,
                                '"}'
                            )
                        )
                    )
                )
            );
    }
}
