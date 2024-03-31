// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * **Testing Plan**
 *
 * Writing this test would require some changes to the test harness since the
 * Timelock is not compatible with the `MerkleGovernorSimple` contract used
 * there.
 *
 * The goal of this test is to have some assurances around the Queueing stage of
 * the lifecycle. This will be (1) light integration test to ensure that a
 * Timelock can be properly integrated with the `MerkleGovernor` and that the
 * changes to the original OZ governor have not affected that functionality.
 *
 * Tests should include assertions against `proposalEta()`.
 *
 * The `relay()` function should also be lightly tested.
 */
contract MerkleGovernorTimelock_IntegrationTest { }
