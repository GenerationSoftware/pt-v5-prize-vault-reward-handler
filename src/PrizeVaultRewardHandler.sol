// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PrizeVault } from "../lib/pt-v5-vault/src/PrizeVault.sol";
import { TwabRewards, SafeERC20, IERC20 } from "../lib/pt-v5-twab-rewards/src/TwabRewards.sol";
import { TwabController } from "../lib/pt-v5-vault/lib/pt-v5-twab-controller/src/TwabController.sol";

/// @title Prize Vault Reward Handler
/// @author G9 Software Inc.
/// @notice Allows for the permissionless distribution of token rewards accrued by this contract
/// to the depositors in the associated prize vault via TWAB reward promotions.
contract PrizeVaultRewardHandler {
    using SafeERC20 for IERC20;
    
    /// @notice The TwabRewards contract to use to create promotions
    TwabRewards public immutable twabRewards;

    /// @notice The prize vault that is earning the rewards
    PrizeVault public immutable prizeVault;

    /// @notice The minimum time in seconds between the start of each promotion
    uint256 public immutable minDistributionSpacing;

    /// @notice The maximum time in seconds that a promotion will span
    /// @dev Promotions will be shortened from the rear to match this length if too long.
    uint256 public immutable maxDistributionTimeSpan;

    /// @notice Mapping of the last distribution end time for each token.
    mapping(address token => uint256 lastDistributionAt) public lastDistribution;

    /// @notice Struct for an arbitrary function call
    /// @param to The target of the call
    /// @param data The calldata
    /// @param value The ether value to call with
    struct Call {
        address to;
        bytes data;
        uint256 value;
    }

    /// @notice Emitted when an arbitrary owner call is made
    /// @param to The target of the call
    /// @param data The calldata
    /// @param value The ether value the call was made with
    event OwnerCall(address indexed to, bytes data, uint256 value);

    /// @notice Emitted when tokens are distributed through a promotion
    /// @param token The token being distributed
    /// @param caller The caller of the distribution function
    /// @param promotionId The TwabRewards promotion ID
    /// @param startTime The start time for the promotion
    /// @param endTime The end time for the promotion
    /// @param amount The amount of tokens distributed
    event TokensDistributed(
        address indexed token,
        address indexed caller,
        uint256 indexed promotionId,
        uint256 startTime,
        uint256 endTime,
        uint256 amount
    );

    /// @notice Thrown if the TWAB controller for the twab rewards and prize vault does not match.
    error TwabControllerMismatch();

    /// @notice Thrown if the sender does not match the prize vault owner for a protected function.
    /// @param sender The sender of the call
    /// @param prizeVaultOwner The owner of the prize vault
    error SenderNotPrizeVaultOwner(address sender, address prizeVaultOwner);

    /// @notice Thrown if a distribution is triggered too soon to the last.
    /// @param timeSinceLastDistribution The time in seconds since the last distribution
    /// @param minDistributionSpacing The minimum distribution spacing in seconds
    error DistributionTooSoon(uint256 timeSinceLastDistribution, uint256 minDistributionSpacing);

    /// @notice Thrown if the min distribution spacing exceeds the max time span.
    /// @param minDistributionSpacing The min distribution spacing set
    /// @param maxDistributionTimeSpan The max distribution time span
    error MinSpacingExceedsMaxTimeSpan(uint256 minDistributionSpacing, uint256 maxDistributionTimeSpan);

    /// @notice Modifier that asserts the sender is the prize vault owner.
    modifier onlyPrizeVaultOwner() {
        if (msg.sender != prizeVault.owner()) {
            revert SenderNotPrizeVaultOwner(msg.sender, prizeVault.owner());
        }
        _;
    }

    /// @notice Constructor
    /// @param twabRewards_ The TwabRewards contract to use for promotions
    /// @param prizeVault_ The prize vault that is earning the rewards
    /// @param minDistributionSpacing_ The minimum time in seconds between the start of each promotion
    constructor(
        TwabRewards twabRewards_,
        PrizeVault prizeVault_,
        uint256 minDistributionSpacing_
    ) {
        if (address(prizeVault_.twabController()) != address(twabRewards_.twabController())) {
            revert TwabControllerMismatch();
        }
        twabRewards = twabRewards_;
        prizeVault = prizeVault_;
        minDistributionSpacing = minDistributionSpacing_;

        // Set the max distribution time span to the GP period since the TWAB controller is guaranteed to support
        // TWAB lookups for this amount of time in the past.
        maxDistributionTimeSpan = prizeVault_.prizePool().grandPrizePeriodDraws() * prizeVault_.prizePool().drawPeriodSeconds();
        if (minDistributionSpacing > maxDistributionTimeSpan) {
            revert MinSpacingExceedsMaxTimeSpan(minDistributionSpacing, maxDistributionTimeSpan);
        }
    }
    
    /// @notice Distributes any accumulated `_token` rewards via a TwabRewards promotion.
    /// @dev Truncates the distribution times to line up with the previously closed TWAB period
    /// @param _token The token to distribute
    function distributeTokens(address _token) external {
        TwabController _twabController = TwabController(address(prizeVault.twabController()));
        uint256 _startTime = lastDistribution[_token];
        uint256 _endTime = _twabController.periodEndOnOrAfter(block.timestamp - _twabController.PERIOD_LENGTH());
        if (_startTime == 0 || _endTime - _startTime > maxDistributionTimeSpan) {
            _startTime = _endTime - maxDistributionTimeSpan;
        }
        uint256 _distributionTimeSpan = _endTime - _startTime;
        if (_distributionTimeSpan < minDistributionSpacing) {
            revert DistributionTooSoon(_distributionTimeSpan, minDistributionSpacing);
        }
        
        // check token balance and approve TwabRewards contract to spend them
        uint256 _promotionTokens = IERC20(_token).balanceOf(address(this));
        IERC20(_token).forceApprove(address(twabRewards), _promotionTokens);

        // create promotion
        uint256 _promotionId = twabRewards.createPromotion(
            address(prizeVault),
            IERC20(_token),
            uint64(_startTime),
            _promotionTokens,
            uint48(_distributionTimeSpan),
            uint8(1)
        );

        // update distribution info
        lastDistribution[_token] = _endTime;
        emit TokensDistributed(
            _token,
            msg.sender,
            _promotionId,
            _startTime,
            _endTime,
            _promotionTokens
        );
    }

    /// @notice Allows the prize vault owner to execute arbitrary calls from this contract
    /// @dev This can be used to manage TWAB rewards created by this contract or withdraw stuck funds.
    /// @dev If any calls fail, this function call will revert.
    /// @param calls The calls to make from this contract
    /// @return returnData The return data from each call
    function ownerCalls(Call[] calldata calls)
        external
        payable
        onlyPrizeVaultOwner
        returns (bytes[] memory returnData)
    {
        bool success;
        returnData = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (success, returnData[i]) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            require(success, string(returnData[i]));
            emit OwnerCall(calls[i].to, calls[i].data, calls[i].value);
        }
    }
    
}
