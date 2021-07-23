// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title   Interface MiningReward
 * @notice  Allows the ERC20SimpleSwap contract to interact with the MiningReward contract
 *          without importing the entire smart contract.
 * @dev     This is not a full interface of the contract, but instead a partial
 *          interface covering only the functions that are needed by the ERC20SimpleSwap.
 */
interface I_MiningReward {
    function join(address beneficiary, address issuer) external;

    function withdraw() external;

    function STAKING_AMOUNT() external returns (uint256);
}
