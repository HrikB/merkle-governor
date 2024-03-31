// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { MerkleGovernorSetup } from "../helpers/MerkleGovernorSetup.sol";

/**
 * **Testing Plan**
 *
 * 1. Test happy path with 1 proposer and 1 voter
 * 2. Test happy path with 1 proposer and multiple (3) voters
 * 3. Test happy path with 2 proposals in a single block and multiple (3) voters
 *      casting on both proposals
 *
 * Each of the above tests should assert against the expected value of the `state()` function.
 *
 * After proposal requests, it should validate the output of `proposalSnapshot()` and `proposalProposer()`.
 *
 * After voter snapshot root is approved, it should validate the output of `proposalDeadline()`.
 */
contract MerkleGovernor_IntegrationTest is MerkleGovernorSetup { }
