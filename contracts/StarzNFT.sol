// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";


/** 
Goals this project trying to achieve...
1. Fairness - by means of raffle
2. Don't create race - by means of auction
3. Prevent exploitation - only reveal metadat after minting of all nfts
*/


contract StarzNFT is ERC721, Pausable, VRFConsumerBaseV2, Ownable {
    

    using Address for address;
    using Counters for Counters.Counter;

    // BaseURI
    string private baseURI;
    // Bool to check whether to reveal metadata or not
    bool reveal;
    // Bool to check whether the true BaseURI is set or not
    bool alreadySet;
    // @notice Winnerlist is created
    bool clearedRaffle;
    // @notice Randomness is requested
    bool randomnessRequested;
    // @notice Price per NFT for winner
    uint256 public immutable RAFFLE_PRICE;
    // @notice raffle supply
    uint32 public constant RAFFLE_SUPPLY = 10;
    // @notice maximum supply of tokens
    uint256 public constant MAX_SUPPLY = 27;
    // @notice raffle starting time
    uint256 public RAFFLE_STARTTIME;
    uint256 public RAFFLE_ENDTIME;
    // Maximum NFT mintable per address in Raffle
    uint256 public maxPerAddress;
    // @notice address to number of raffle entries
    mapping(address => uint) personToNumberOfNFT;
    // @notice address to number of NFT winner can claim
    mapping(address => uint) userCanClaim;
    address[] public raffleEntries;


    // =========== VRF variables ============
    

    VRFCoordinatorV2Interface COORDINATOR;
    // Your subscription ID.
    uint64 subscriptionId;

    // Rinkeby coordinator. For other networks,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    address vrfCoordinator;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 keyHash;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFCoordinatorV2.MAX_NUM_WORDS.
    uint32 numWords =  RAFFLE_SUPPLY;
    // Array to save randomwords received from VRF
    uint256[] public randomWords;
    uint256 public requestId;


    // ============ Auction Variables ==========
    // Keep track of highest bidder
    address public highestBidder;
    // Highestbid
    uint public highestBid;
    // Mapping to keep track of who bided how much
    mapping(address => uint) public bids;
    uint256 auctionDuration;

    // Owner withdrawable balance
    uint256 ownerCanWithdraw;




    event RaffleEntered(address indexed user, uint256 amount);
    event RandomnumbersRequested(uint256 requestId);
    event RaffleCleared();
    event RaffleClaimed(address indexed claimer, uint256 nftClaimed);
    event Bid(address indexed bidder, uint256 bid);
    event Withdraw(address indexed receiver, uint256 value);

    Counters.Counter private _tokenIdCounter;

    constructor(string memory _fakeBaseURI,
                uint256 _price,
                uint256 _maxPerAddress,
                uint64 _subscriptionId,
                address _vrfCoordinator,
                bytes32 _keyHash)
                ERC721("Starz NFT", "STZNFT")
                VRFConsumerBaseV2(_vrfCoordinator)
                {
        baseURI = _fakeBaseURI;
        RAFFLE_PRICE = _price;
        RAFFLE_STARTTIME = block.timestamp + 1 hours;
        RAFFLE_ENDTIME = RAFFLE_STARTTIME + 3 minutes;
        maxPerAddress = _maxPerAddress;
        subscriptionId = _subscriptionId;
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        keyHash = _keyHash;
    }

    /**
     * @notice create a raffle 
     * @ _amount of nft user wants to buy
     */
    function enterRaffle(uint256 _amount) public {
        require(block.timestamp >= RAFFLE_STARTTIME, "Raffle not started yet");
        require(block.timestamp <= RAFFLE_ENDTIME, "Raffle ended");
        require(_amount <= maxPerAddress, "Only `maxPerAddress` allowed per address");
        require(personToNumberOfNFT[msg.sender] + _amount <= maxPerAddress, "Only `maxPerAddress` allowed per address");
        require(!Address.isContract(msg.sender),"contracts are not allowed");
        personToNumberOfNFT[msg.sender] += _amount;
        for (uint i; i < _amount; i++) {
            raffleEntries.push(msg.sender);
        }
        emit RaffleEntered(msg.sender, _amount);
    }

    function requestRandomness() external {
        // Check that it's not already called
        require(!randomnessRequested, "Randomness already requested");
        require(block.timestamp > RAFFLE_ENDTIME, "Raffle not ended yet");
        require(raffleEntries.length > RAFFLE_SUPPLY, "No need to call randomness");
        requestId = COORDINATOR.requestRandomWords(
                                    keyHash,
                                    subscriptionId,
                                    requestConfirmations,
                                    callbackGasLimit,
                                    numWords
                                    );
        emit RandomnumbersRequested(requestId);
    }

    function clearRaffle() public onlyOwner {
        require(!clearedRaffle, "Raffle already cleared");
        require(block.timestamp > RAFFLE_ENDTIME, "Raffle not ended yet");
        require(raffleEntries.length > RAFFLE_SUPPLY, "No need to call randomness");
        require(randomnessRequested, "Randomness not requested");
        clearedRaffle = true;
        for (uint i; i < RAFFLE_SUPPLY; i++) {
            uint256 randomIndex = randomWords[i] % (raffleEntries.length - 1);
            address winner = raffleEntries[randomIndex];
            raffleEntries[randomIndex] = raffleEntries[i];
            raffleEntries[i] = winner;
            userCanClaim[winner]++;
        }
        emit RaffleCleared();
        auctionDuration = block.timestamp + 1 hours;
    }

    function checkEligibility() public view returns (uint256 nftClaimable) {
        nftClaimable = userCanClaim[msg.sender];
    }

    function claim(uint256 _amountToBeClaimed) external payable {
        // Ensure following
        // 1. Raffle is cleared and winner list is created
        // 2. user has not already claimed
        // 3. Enough Eth is paid
        require(clearedRaffle && randomnessRequested, "Raffle is not cleared yet");
        require(userCanClaim[msg.sender] >= _amountToBeClaimed, "You are not eligible to claim entered amount");
        require((_amountToBeClaimed * RAFFLE_PRICE) <= msg.value, "Not enough Eth");
        userCanClaim[msg.sender] -= _amountToBeClaimed;
        for (uint i; i < _amountToBeClaimed; i++) {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(msg.sender, tokenId);
        ownerCanWithdraw+=RAFFLE_PRICE;
        }

        emit RaffleClaimed(msg.sender, _amountToBeClaimed);
    }





  
    function fulfillRandomWords(
      uint256, /** _requestId */
      uint256[] memory _randomWords
    ) internal override {
      randomnessRequested = true;
      randomWords = _randomWords;
    }

    /** 
    * Once raffle is over. Auction starts. Each auction last for 1 Hours. Those who wants to buy the next NFT can bid. 
    * But only with the amount higher than current hihestBid. All other bidders would be able to withdraw their bids.
    * At the end of and only after 1 hour mint function can be called by anyone and it will mint NFT to the user with highest bid.
    * User needs to pay while bidding.
    * When One NFT is minted, bid starts from scratch
    */
    function bid() external payable {
        require(MAX_SUPPLY > _tokenIdCounter.current(), "All token minted");
        // Make sure raffle cleared
        require(clearedRaffle, "Auction not started yet");
        // Bid amount must be higher than the current highest bid
        require(msg.value > highestBid, "Amount less than highest bid");
        // we are not storing the curent highest bidder and highest bid in mapping, we are only storing the previous highestBidder and their bids
        // Only if there is some bid then update the mapping and there override it
        if (highestBidder != address(0)) {
            bids[highestBidder] += highestBid; 
        }
        highestBid = msg.value; // IN case of first bidder these 2 lines will execute, and code inside if statement won't execute.
        highestBidder = msg.sender;
        emit Bid(msg.sender, msg.value);

    } 


    function mint() external {
        require(block.timestamp >= auctionDuration, "Auction not ended yet");
        require(highestBidder != address(0), "No bid received");

        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        ownerCanWithdraw += highestBid;
        highestBidder = address(0);
        highestBid = 0;
        _safeMint(highestBidder, tokenId);
        

    }


    // Only people who are not highest bidder will be able to withdraw 
    function withdraw() external {
        if (msg.sender == owner()) {
            (bool success, ) = payable(owner()).call{value: ownerCanWithdraw}("");
            require(success, "Payment Failed");
            ownerCanWithdraw = 0;
        }
        uint bal = bids[msg.sender];
        bids[msg.sender] =  0;

        (bool sent, ) = payable(msg.sender).call{value: bal}("");
        require(sent, "Payment Failed");
        emit Withdraw(msg.sender, bal);
    }









    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function safeMint(address to) public onlyOwner {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        whenNotPaused
        override
    {
        super._beforeTokenTransfer(from, to, tokenId);
    }


    // TO BE COMPLETED
    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    function setBaseURI(string calldata _realBaseURI) public onlyOwner {
        require(reveal, "Reveal is false");
        require(!alreadySet, "BaseURI can't be changed again");
        alreadySet = true;
        baseURI = _realBaseURI;
    }


    receive() payable external {}

    fallback() payable external {}
}
