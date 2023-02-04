// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/base/LiquidityManagement.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "hardhat/console.sol";


contract LiquidityProvider is IERC721Receiver {
    using EnumerableSet for EnumerableSet.UintSet;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;
    int24 private constant TICK_SPACING = 60;

    address public fundAddress;
    INonfungiblePositionManager public immutable nftPositionsManager;

    /**
     * Define events here
     */
    event PositionMinted(uint256 tokenId);
    event PositionLiquidityModified(uint256 tokenId, uint128 liquidity);

    // LP position
    struct LPPosition {
        // "owner" in here is the "fundManager"
        address owner;
        uint128 liquidity;
        address token0;
        address token1;
        uint256 tokenId;
    }

    // Map "tokenId" to "LPPosition"
    mapping(uint256 => LPPosition) public tokenIdToLpPositions;
    EnumerableSet.UintSet private lpPositionsTokenIds;

    // Keep track of ERC20 token balances 
    mapping(address => uint256) public tokenBalances;
    address[] public tokenAddresses;

    constructor(address _nftPositionsManager) {
        fundAddress = msg.sender;
        nftPositionsManager = INonfungiblePositionManager(_nftPositionsManager);
    }

    function _createDeposit(address owner, uint256 tokenId) internal {
      // https://docs.uniswap.org/contracts/v3/reference/periphery/interfaces/INonfungiblePositionManager
      (
          ,
          ,
          address token0,
          address token1,
          ,
          ,
          ,
          uint128 liquidity,
          ,
          ,
          ,
      ) = nftPositionsManager.positions(tokenId);

      tokenIdToLpPositions[tokenId] = LPPosition({
          owner: owner,
          liquidity: liquidity,
          token0: token0,
          token1: token1,
          tokenId: tokenId
      });
      EnumerableSet.add(lpPositionsTokenIds, tokenId);
    }

    function _setLiquidity(uint256 tokenId, uint128 liquidity) internal {
        tokenIdToLpPositions[tokenId].liquidity = liquidity;
        emit PositionLiquidityModified(tokenId, liquidity);
    }

    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity) internal {
        uint128 prevLiquidity = tokenIdToLpPositions[tokenId].liquidity;
        _setLiquidity(tokenId, prevLiquidity - liquidity);
    }

    function _removeLPPosition(uint256 tokenId) internal {
        EnumerableSet.remove(lpPositionsTokenIds, tokenId);
        delete tokenIdToLpPositions[tokenId];
    }

    function _sendToOwner(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) internal {
        LPPosition memory deposit = tokenIdToLpPositions[tokenId];
        // Transfer token0 to owner
        TransferHelper.safeTransfer(deposit.token0, deposit.owner, amount0);
        // Transfer token1 to owner
        TransferHelper.safeTransfer(deposit.token1, deposit.owner, amount1);
    }


    // V3 position is represented by NFT minted from Uniswap V3 NFT Position Manager
    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/IERC721Receiver.sol
    function onERC721Received(
        address operator,
        address,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        _createDeposit(operator, tokenId);

        return this.onERC721Received.selector;
    }

    /**
     * Returns the ERC20 token addresses and balances of the contract
     */
    function getTokenBalances() external view returns (address[] memory, uint256[] memory) {
        uint256[] memory balances = new uint256[](tokenAddresses.length);
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            balances[i] = tokenBalances[tokenAddresses[i]];
        }
        return (tokenAddresses, balances);
    }

    /**
     * Returns the LP positions of the contract
     */
    function getActiveLpPositions() external view returns (LPPosition[] memory) {
        LPPosition[] memory activeLpPositions = new LPPosition[](EnumerableSet.length(lpPositionsTokenIds));
        for (uint256 i = 0; i < activeLpPositions.length; i++) {
            activeLpPositions[i] = tokenIdToLpPositions[EnumerableSet.at(lpPositionsTokenIds, i)];
        }
        return activeLpPositions;
    }


    function mintPosition(
        address token0,
        uint256 amount0ToMint,
        address token1,
        uint256 amount1ToMint,
        int24 lowerTick,
        int24 upperTick,
        uint24 poolFee
    )
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        TransferHelper.safeTransferFrom(token0, msg.sender, address(this), amount0ToMint);
        TransferHelper.safeTransferFrom(token1, msg.sender, address(this), amount1ToMint);

        TransferHelper.safeApprove(token0, address(nftPositionsManager), amount0ToMint);
        TransferHelper.safeApprove(token1, address(nftPositionsManager), amount1ToMint);

            
        if (lowerTick == 0) {
            lowerTick = (MIN_TICK / TICK_SPACING) * TICK_SPACING;
        }

        if (upperTick == 0) {
            upperTick = (MAX_TICK / TICK_SPACING) * TICK_SPACING;
        }

        // Mint position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: poolFee,
            // Customize tickLower & tickUpper to optimize swap fees, depending on LP strategy
            tickLower: lowerTick,
            tickUpper: upperTick,
            amount0Desired: amount0ToMint,
            amount1Desired: amount1ToMint,
            // Slippage, risky to front running attacks
            // https://uniswapv3book.com/docs/milestone_3/slippage-protection/
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tokenId, liquidity, amount0, amount1) = nftPositionsManager.mint(params);

        _createDeposit(msg.sender, tokenId);

        // Refund any remaining tokens that were not used during LP minting
        if (amount0 < amount0ToMint) {
            TransferHelper.safeApprove(token0, address(nftPositionsManager), amount0);
            TransferHelper.safeTransfer(
                token0,
                msg.sender,
                amount0ToMint - amount0
            );
        }

        if (amount1 < amount1ToMint) {
            TransferHelper.safeApprove(token1, address(nftPositionsManager), amount1);
            TransferHelper.safeTransfer(
                token1,
                msg.sender,
                amount1ToMint - amount1
            );
        }

        emit PositionMinted(tokenId);
    }

    function redeemPosition(uint256 tokenId)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(tokenIdToLpPositions[tokenId].owner == msg.sender, "Not owner of position");

        (amount0, amount1) = nftPositionsManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        _sendToOwner(tokenId, amount0, amount1);
        _removeLPPosition(tokenId);


        return (amount0, amount1);
    }

    function increasePositionLiquidity(
        uint256 tokenId,
        uint256 amount0ToMint,
        uint256 amount1ToMint,
        address fundManager
    ) public returns (
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {
        require(tokenIdToLpPositions[tokenId].owner == fundManager, "Not owner of position");

        // Require that the caller is the fund manager & has approved the tokens
        TransferHelper.safeTransferFrom(tokenIdToLpPositions[tokenId].token0, msg.sender, address(this), amount0ToMint);
        TransferHelper.safeTransferFrom(tokenIdToLpPositions[tokenId].token1, msg.sender, address(this), amount1ToMint);

        TransferHelper.safeApprove(tokenIdToLpPositions[tokenId].token0, address(nftPositionsManager), amount0ToMint);
        TransferHelper.safeApprove(tokenIdToLpPositions[tokenId].token1, address(nftPositionsManager), amount1ToMint);

        (liquidity, amount0, amount1) = nftPositionsManager.increaseLiquidity(
        INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId: tokenId,
            amount0Desired: amount0ToMint,
            amount1Desired: amount1ToMint,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        })
        );

        _setLiquidity(tokenId, liquidity);

        return (liquidity, amount0, amount1);
    }

    function decreasePositionLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        address fundManager
    ) public returns (
        uint256 amount0,
        uint256 amount1
    ) {
        require(tokenIdToLpPositions[tokenId].owner == fundManager, "Not owner of position");

        (amount0, amount1) = nftPositionsManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        _decreaseLiquidity(tokenId, liquidity);

        console.log("tokenIdToLpPositions[tokenId]", tokenIdToLpPositions[tokenId].token0);

        console.log("amount0", amount0);
        console.log("amount1", amount1);

        console.log("balance(amount0)", IERC20(tokenIdToLpPositions[tokenId].token0).balanceOf(address(this)));
        console.log("balance(amount1)", IERC20(tokenIdToLpPositions[tokenId].token1).balanceOf(address(this)));
        _sendToOwner(tokenId, amount0, amount1);
    
        return (amount0, amount1);
    }


    /**
    * Returns the list of LP positions tokenIds 
    */
    function getLpPositionsTokenIds() public view returns (uint256[] memory) {
        uint256[] memory lpPositionsTokenIdsArr = new uint256[](EnumerableSet.length(lpPositionsTokenIds));
        for (uint256 i = 0; i < lpPositionsTokenIdsArr.length; i++) {
        lpPositionsTokenIdsArr[i] = EnumerableSet.at(lpPositionsTokenIds, i);
        }
        return lpPositionsTokenIdsArr;
    }

}
