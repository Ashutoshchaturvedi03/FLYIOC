// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
 
contract FlytPreSale is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
 
    mapping(address => uint256) public tokensBought;
 
    address public multiSignTreasuryWallet;
    IERC20 immutable flytToken;
    IERC20 immutable usdtToken;
    uint256 public tokenPrice; // Token Price is per USDT eg. 1USDT=2FLYT and must be with proper 18 decimals format
 
    AggregatorV3Interface public priceFeed; // Chainlink price feed;
    uint256 immutable priceStaleThreshold = 1 hours;
    uint256 public minThresholdLimit; // Minimum buy value in USDT
 
    event TokensPurchased(address indexed buyer, uint256 amount);
    event FlytTokenAddressUpdated(address indexed newAddress);
    event AggregatorPairUpdated(address indexed newPairAddress);
    event minThresholdUpdated(uint256 indexed newMinThresholdLimit);
    event TokenPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event TokensWithdrawn(address indexed admin, uint256 amount);
    event ETHWithdrawn(address indexed admin, uint256 amount);
    event TreasuryWalletUpdated(address indexed newWallet);
 
    // _tokenPrice should be in 18 decimals format.
    // _minBuyValueInUSDT value should be in usdt with 6 decimals
    constructor(
        uint256 _tokenPrice,
        address multiSigWallet,
        uint256 _minThresholdLimit,
        address _flytToken,
        address _usdttoken
    ) Ownable(multiSigWallet) {
        flytToken = IERC20(_flytToken); //FlytToken Contract Address
        usdtToken = IERC20(_usdttoken); // USDT Contract Address
        tokenPrice = _tokenPrice;
        multiSignTreasuryWallet = multiSigWallet;
        minThresholdLimit = _minThresholdLimit;
        priceFeed = AggregatorV3Interface(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1); // ETH/USD Pair Price Feed Address on base sepolia testnet
        //0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70 ETH/USD Price feed address on Base mainnet.
    }
 
    //---------------------------------------For Base Sepolia testing logic------------------------------------
 
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt <= priceStaleThreshold,"Price data is stale");
        return uint256(price);
    }
 
    function buyTokens() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "Must send some ETH");
        uint256 ETHPriceInUSDT = getLatestPrice(); // price in 8 decimal format
        // Calculate the equivalent amount of USDT
        uint256 ETHAmountInUSDT = (ETHPriceInUSDT * msg.value);
        // Calculate the amount of FLYT tokens to send
        uint256 flytTokQty = (ETHAmountInUSDT * tokenPrice)/1e26;
        require(flytTokQty > 0, "Invalid Purchase");
        require(
            flytToken.balanceOf(address(this)) >= flytTokQty,
            "Insufficent Tokens"
        );
 
        flytToken.safeTransfer(msg.sender, flytTokQty);
        (bool success, ) = payable(multiSignTreasuryWallet).call{
            value: msg.value
        }("");
        require(success, "Failed to transfer ETH");
 
        tokensBought[msg.sender] = tokensBought[msg.sender] + flytTokQty;
        emit TokensPurchased(msg.sender, flytTokQty);
    }
 
     function buyTokenWithUsdt(uint256 usdtAmount)
        external
        whenNotPaused
        nonReentrant
    {
        require(usdtAmount > 0, "Must send some USDT");
        require(usdtAmount >= minThresholdLimit, "Less Than Threshold");
 
        // Calculate the number of FLYT Tokens to be bought
        uint256 flytTokAmount = (usdtAmount * tokenPrice) / 1e6; // Adjust for 18 decimals
        require(flytTokAmount > 0, "FLYT Token too Small");
 
        // Check if there are enough tokens in the contract
        require(
            flytToken.balanceOf(address(this)) >= (flytTokAmount),
            "Insufficient FLYT bal"
        );
 
        // Transfer USDT to the treasury wallet
        usdtToken.safeTransferFrom(
            msg.sender,
            multiSignTreasuryWallet,
            usdtAmount
        );
 
        // Transfer FLYT to the buyer
        flytToken.safeTransfer(msg.sender, flytTokAmount);
 
        tokensBought[msg.sender] = tokensBought[msg.sender] + flytTokAmount;
 
        emit TokensPurchased(msg.sender, flytTokAmount);
    }
 
    // Functions
    function updateTreasuryWallet(address _multiSigWallet) external onlyOwner {
        require(_multiSigWallet != address(0), "Invalid Treasury Wallet");
        require(multiSignTreasuryWallet != _multiSigWallet, "Use Diff. Wallet");
        multiSignTreasuryWallet = _multiSigWallet;
        emit TreasuryWalletUpdated(_multiSigWallet);
    }
 
    function withdrawProfit() external onlyOwner {
        uint256 totalBalance = address(this).balance;
        (bool sent, ) = multiSignTreasuryWallet.call{value: totalBalance}("");
        if (sent == false) revert("ETH Transfer Failed");
    }
 
    function withdrawTokens(address tokenAddress, uint256 amount)
        external
        onlyOwner
    {
        require(amount > 0, "Amount must be greater than 0");
        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) > 0, "Insufficient token");
        if (token.balanceOf(address(this)) < amount) {
            amount = token.balanceOf(address(this));
        }
        token.safeTransfer(multiSignTreasuryWallet, amount);
        emit TokensWithdrawn(msg.sender, amount); // Emit event
    }
 
    // Token Price must be in 18 decimals.
    function setTokenPrice(uint256 _newTokenPrice) external onlyOwner {
        require(_newTokenPrice > 0, "Price must be greater than 0");
        uint256 oldTokenPrice = tokenPrice; // Cache the old token price
        tokenPrice = _newTokenPrice;
        emit TokenPriceUpdated(oldTokenPrice, _newTokenPrice); // Emit event
    }
 
    // Update the minimum buy value in USDT
    function setMinThreshold(uint256 _minThresholdLimit) external onlyOwner {
        require(_minThresholdLimit > 0, "Threshold must be greater than 0");
        minThresholdLimit = _minThresholdLimit;
        emit minThresholdUpdated(_minThresholdLimit); // Emit event
    }
 
    function updateAggregatorPairAddress(address _newPairAddress)
        external
        onlyOwner
    {
        require(_newPairAddress != address(0), "Invalid Pair address");
        priceFeed = AggregatorV3Interface(_newPairAddress); // ETH/USD Pair Price Feed Address
        emit AggregatorPairUpdated(_newPairAddress);
    }
 
    function getContractBal(address _tokenAddress)
        public
        view
        returns (uint256)
    {
        require(_tokenAddress != address(0), "Invalid token address");
        return IERC20(_tokenAddress).balanceOf(address(this));
    }
 
    receive() external payable {}
}