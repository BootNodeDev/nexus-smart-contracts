// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.9;

import "../../interfaces/INXMToken.sol";
import "../../interfaces/IMemberRoles.sol";
import "../../interfaces/IPool.sol";
import "../../interfaces/ICover.sol";
import "../../interfaces/IClaims.sol";
import "../../interfaces/IAssessment.sol";
import "../../interfaces/IERC20Detailed.sol";
import "../../interfaces/ICoverNFT.sol";

import "../../abstract/MasterAwareV2.sol";

/// Provides a way for cover owners to submit claims and redeem payouts. It is an entry point to
/// the assessment process where the members of the mutual decide the outcome of claims.
contract Claims is IClaims, MasterAwareV2 {

  // 0-10000 bps (i.e. double decimal precision percentage)
  uint internal constant MIN_ASSESSMENT_DEPOSIT_DENOMINATOR = 10000;
  uint internal constant REWARD_DENOMINATOR = 10000;

  // Used in operations involving NXM tokens and divisions
  uint internal constant PRECISION = 10 ** 18;

  INXMToken internal immutable nxm;
  ICoverNFT internal immutable coverNFT;

  /* ========== STATE VARIABLES ========== */

  Configuration public override config;

  Claim[] public override claims;

  // Mapping from coverId to claimId used to check if a new claim can be submitted on the given
  // cover as long as the last submitted claim reached a final state.
  mapping(uint => ClaimSubmission) public lastClaimSubmissionOnCover;

  /* ========== CONSTRUCTOR ========== */

  constructor(address nxmAddress, address coverNFTAddress) {
    nxm = INXMToken(nxmAddress);
    coverNFT = ICoverNFT(coverNFTAddress);
  }

  function initialize(address masterAddress) external {
    // The minimum cover premium per year is 2.6%. 20% of the cover premium is: 2.6% * 20% = 0.52%
    config.rewardRatio = 130; // 1.3%
    config.maxRewardInNXMWad = 50; // 50 NXM
    config.minAssessmentDepositRatio = 500; // 5% i.e. 0.05 ETH assessment minimum flat fee
    config.payoutRedemptionPeriodInDays = 14; // days until the payout will not be redeemable anymore
    master = INXMMaster(masterAddress);
  }

  /* ========== VIEWS ========== */

  function min(uint a, uint b) internal pure returns (uint) {
    return a < b ? a : b;
  }

  function cover() internal view returns (ICover) {
    return ICover(getInternalContractAddress(ID.CO));
  }

  function assessment() internal view returns (IAssessment) {
    return IAssessment(getInternalContractAddress(ID.AS));
  }

  function pool() internal view returns (IPool) {
    return IPool(getInternalContractAddress(ID.P1));
  }

  function getClaimsCount() external override view returns (uint) {
    return claims.length;
  }

  function _getAssessmentDepositAndReward(
    uint requestedAmount,
    uint segmentPeriod,
    uint payoutAsset
  ) internal view returns (uint, uint) {
    IPool poolContract = pool();
    uint nxmPriceInPayoutAsset = poolContract.getTokenPrice(payoutAsset);
    uint nxmPriceInETH = poolContract.getTokenPrice(0);

    // Calculate the expected payout in NXM using the NXM price at cover purchase time
    uint expectedPayoutInNXM = requestedAmount * PRECISION / nxmPriceInPayoutAsset;

    // Determine the total rewards that should be minted for the assessors based on cover period
    uint totalReward = min(
      uint(config.maxRewardInNXMWad) * PRECISION,
      expectedPayoutInNXM * uint(config.rewardRatio) * segmentPeriod / 365 days / REWARD_DENOMINATOR
    );

    uint dynamicDeposit = totalReward * nxmPriceInETH / PRECISION;
    uint minDeposit = 1 ether * uint(config.minAssessmentDepositRatio) /
      MIN_ASSESSMENT_DEPOSIT_DENOMINATOR;

    // If dynamicDeposit falls below minDeposit use minDeposit instead
    uint deposit = minDeposit > dynamicDeposit ? minDeposit : dynamicDeposit;

    return (deposit, totalReward);
  }

  /// Returns the required deposit and total reward for a new claim
  ///
  /// @dev This view is meant to be used either by users or user interfaces to determine the
  /// minimum deposit value of the submitClaim tx.
  ///
  /// @param requestedAmount  The amount that is claimed
  /// @param segmentPeriod    The cover period of the segment in days
  /// @param payoutAsset      The asset in which the payout would be made
  function getAssessmentDepositAndReward(
    uint requestedAmount,
    uint segmentPeriod,
    uint payoutAsset
  ) external view returns (uint, uint) {
    return _getAssessmentDepositAndReward(requestedAmount, segmentPeriod, payoutAsset);
  }

  /// Returns a Claim aggregated in a human-friendly format.
  ///
  /// @dev This view is meant to be used in user interfaces to get a claim in a format suitable for
  /// displaying all relevant information in as few calls as possible. See ClaimDisplay struct.
  ///
  /// @param id    Claim identifier for which the ClaimDisplay is returned
  function getClaimDisplay(uint id) internal view returns (ClaimDisplay memory) {
    Claim memory claim = claims[id];
    (IAssessment.Poll memory poll,,) = assessment().assessments(claim.assessmentId);

    ClaimStatus claimStatus;
    PayoutStatus payoutStatus;
    {
      // Determine the claims status
      if (block.timestamp < poll.end) {
        claimStatus = ClaimStatus.PENDING;
      } else if (poll.accepted > poll.denied) {
        claimStatus = ClaimStatus.ACCEPTED;
      } else {
        claimStatus = ClaimStatus.DENIED;
      }

      // Determine the payout status
      if (claimStatus == ClaimStatus.ACCEPTED) {
        if (claim.payoutRedeemed) {
          payoutStatus = PayoutStatus.COMPLETE;
        } else {
          (,,uint8 payoutCooldownInDays,) = assessment().config();
          if (
            block.timestamp >= poll.end +
            payoutCooldownInDays * 1 days +
            config.payoutRedemptionPeriodInDays * 1 days
          ) {
            payoutStatus = PayoutStatus.UNCLAIMED;
          } else {
            payoutStatus = PayoutStatus.PENDING;
          }
        }
      } else if (claimStatus == ClaimStatus.DENIED) {
        payoutStatus = PayoutStatus.DENIED;
      } else {
        payoutStatus = PayoutStatus.PENDING;
      }
    }

    CoverData memory coverData = cover().coverData(claim.coverId);

    CoverSegment memory segment = cover().coverSegments(claim.coverId, claim.segmentId);

    uint segmentEnd = segment.start + segment.period;

    string memory assetSymbol;
    if (claim.payoutAsset == 0) {
      assetSymbol = "ETH";
    } else {
      (
        address payoutAsset,
        /*uint8 decimals*/,
        /*bool deprecated*/
      ) = pool().assets(claim.payoutAsset);
      try IERC20Detailed(payoutAsset).symbol() returns (string memory v) {
        assetSymbol = v;
      } catch {
        // return assetSymbol as an empty string and use claim.payoutAsset instead in the UI
      }
    }

    return ClaimDisplay(
      id,
      coverData.productId,
      claim.coverId,
      claim.amount,
      assetSymbol,
      claim.payoutAsset,
      segment.start,
      segmentEnd,
      poll.start,
      poll.end,
      uint(claimStatus),
      uint(payoutStatus)
    );
  }

  /// Returns an array of claims aggregated in a human-friendly format.
  ///
  /// @dev This view is meant to be used in user interfaces to get claims in a format suitable for
  /// displaying all relevant information in as few calls as possible. It can be used to paginate
  /// claims by providing the following paramterers:
  ///
  /// @param ids   Array of Claim ids which are returned as ClaimDisplay
  function getClaimsToDisplay (uint104[] calldata ids)
  external view returns (ClaimDisplay[] memory) {
    ClaimDisplay[] memory claimDisplays = new ClaimDisplay[](ids.length);
    for (uint i = 0; i < ids.length; i++) {
      uint104 id = ids[i];
      claimDisplays[i] = getClaimDisplay(id);
    }
    return claimDisplays;
  }

  /* === MUTATIVE FUNCTIONS ==== */

  /// @dev Migrates covers for arNFT-like contracts that don't use Gateway.sol
  ///
  /// @param coverId          Legacy (V1) cover identifier
  function submitClaim(uint coverId) external override {
    cover().migrateCoverFromOwner(coverId, msg.sender, tx.origin);
  }

  /// Submits a claim for assessment
  ///
  /// @dev This function requires an ETH assessment fee. See: _getAssessmentDepositAndReward
  ///
  /// @param coverId          Cover identifier
  /// @param requestedAmount  The amount expected to be received at payout
  /// @param ipfsMetadata     An IPFS hash that stores metadata about the claim that is emitted as
  ///                         an event. It's required for proof of loss. If this string is empty,
  ///                         no event is emitted.
  function submitClaim(
    uint32 coverId,
    uint16 segmentId,
    uint96 requestedAmount,
    string calldata ipfsMetadata
  ) external payable override onlyMember returns (Claim memory) {
    require(
      coverNFT.isApprovedOrOwner(msg.sender, coverId),
      "Only the owner or approved addresses can submit a claim"
    );

    {
      ClaimSubmission memory previousSubmission = lastClaimSubmissionOnCover[coverId];
      if (previousSubmission.exists) {
        uint80 assessmentId = claims[previousSubmission.claimId].assessmentId;
        IAssessment.Poll memory poll = assessment().getPoll(assessmentId);
        (,,uint8 payoutCooldownInDays,) = assessment().config();
        if (block.timestamp >= poll.end + payoutCooldownInDays * 1 days) {
          if (
            poll.accepted > poll.denied &&
            block.timestamp < poll.end +
            payoutCooldownInDays * 1 days +
            config.payoutRedemptionPeriodInDays * 1 days
          ) {
            revert("A payout can still be redeemed");
          }
        } else {
          revert("A claim is already being assessed");
        }
      }
      lastClaimSubmissionOnCover[coverId] = ClaimSubmission(uint80(claims.length), true);
    }

    ICover coverContract = cover();
    CoverData memory coverData = cover().coverData(coverId);
    CoverSegment memory segment = cover().coverSegments(coverId, segmentId);

    {
      Product memory product = coverContract.products(coverData.productId);
      ProductType memory productType = coverContract.productTypes(product.productType);

      require(
        productType.redeemMethod == uint8(RedeemMethod.Claim),
        "Invalid redeem method"
      );
      require(requestedAmount <= segment.amount, "Covered amount exceeded");
      require(segment.start <= block.timestamp, "Cover starts in the future");
      require(
        segment.start + segment.period + productType.gracePeriodInDays * 1 days > block.timestamp,
        "Cover is outside the grace period"
      );
    }

    Claim memory claim = Claim(
      0,
      coverId,
      segmentId,
      requestedAmount,
      coverData.payoutAsset,
      false // payoutRedeemed
    );

    (uint deposit, uint totalReward) = _getAssessmentDepositAndReward(
      requestedAmount,
      segment.period,
      coverData.payoutAsset
    );

    require(msg.value >= deposit, "Assessment deposit is insufficient");
    if (msg.value > deposit) {
      // Refund ETH excess back to the sender
      (bool refunded, /* bytes data */) = msg.sender.call{value: msg.value - deposit}("");
      require(refunded, "Assessment deposit excess refund failed");
    }

    // Transfer the deposit to the pool
    (bool transferSucceeded, /* bytes data */) =  getInternalContractAddress(ID.P1).call{value: deposit}("");
    require(transferSucceeded, "Assessment deposit transfer to pool failed");

    uint newAssessmentId = assessment().startAssessment(totalReward, deposit);
    claim.assessmentId = uint80(newAssessmentId);
    claims.push(claim);

    if (bytes(ipfsMetadata).length > 0) {
      emit MetadataSubmitted(claims.length - 1, ipfsMetadata);
    }

    return (claim);
  }

  /// Redeems payouts for accepted claims
  ///
  /// @dev Anyone can call this function, the payout always being transfered to the NFT owner.
  /// When the tokens are transfered the assessment deposit is also sent back.
  ///
  /// @param claimId  Claim identifier
  function redeemClaimPayout(uint104 claimId) external override {
    Claim memory claim = claims[claimId];
    (
      IAssessment.Poll memory poll,
      /*uint128 totalAssessmentReward*/,
      uint assessmentDeposit
    ) = assessment().assessments(claim.assessmentId);

    require(block.timestamp >= poll.end, "The claim is still being assessed");
    require(poll.accepted > poll.denied, "The claim needs to be accepted");

    (,,uint8 payoutCooldownInDays,) = assessment().config();
    require(
      block.timestamp >= poll.end + payoutCooldownInDays * 1 days,
      "The claim is in cooldown period"
    );

    require(
      block.timestamp < poll.end +
      payoutCooldownInDays * 1 days +
      config.payoutRedemptionPeriodInDays * 1 days,
      "The redemption period has expired"
    );

    require(!claim.payoutRedeemed, "Payout has already been redeemed");
    claims[claimId].payoutRedeemed = true;

    address payable coverOwner = payable(cover().performPayoutBurn(
      claim.coverId,
      claim.segmentId,
      claim.amount
    ));

    IPool poolContract = pool();
    if (claim.payoutAsset == 0 /* ETH */) {
      poolContract.sendPayout(
        claim.payoutAsset,
        coverOwner,
        claim.amount + assessmentDeposit
      );
    } else {
      poolContract.sendPayout(0 /* ETH */, coverOwner, assessmentDeposit);
      poolContract.sendPayout(claim.payoutAsset, coverOwner, claim.amount);
    }

  }

  /// Allows to update configurable aprameters through governance
  ///
  /// @param paramNames  An array of elements from UintParams enum
  /// @param values      An array of the new values, each one corresponding to the parameter
  ///                    from paramNames on the same position.
  function updateUintParameters(
    UintParams[] calldata paramNames,
    uint[] calldata values
  ) external override onlyGovernance {
    Configuration memory newConfig = config;
    for (uint i = 0; i < paramNames.length; i++) {
      if (paramNames[i] == UintParams.payoutRedemptionPeriodInDays) {
        newConfig.payoutRedemptionPeriodInDays = uint8(values[i]);
        continue;
      }
      if (paramNames[i] == UintParams.rewardRatio) {
        newConfig.rewardRatio = uint16(values[i]);
        continue;
      }
      if (paramNames[i] == UintParams.maxRewardInNXMWad) {
        newConfig.maxRewardInNXMWad = uint16(values[i]);
        continue;
      }
      if (paramNames[i] == UintParams.minAssessmentDepositRatio) {
        newConfig.minAssessmentDepositRatio = uint16(values[i]);
        continue;
      }
    }
    config = newConfig;
  }

  /// @dev Updates internal contract addresses to the ones stored in master. This function is
  /// automatically called by the master contract when a contract is added or upgraded.
  function changeDependentContractAddress() external override {
    internalContracts[uint(ID.TC)] = master.getLatestAddress("TC");
    internalContracts[uint(ID.MR)] = master.getLatestAddress("MR");
    internalContracts[uint(ID.P1)] = master.getLatestAddress("P1");
    internalContracts[uint(ID.CO)] = master.getLatestAddress("CO");
    internalContracts[uint(ID.AS)] = master.getLatestAddress("AS");
  }
}
