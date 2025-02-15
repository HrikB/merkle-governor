// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { IERC165, ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { DoubleEndedQueue } from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { IERC6372 } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import { IMerkleGovernor } from "./IMerkleGovernor.sol";
import { ICheckpointOracle } from "./ICheckpointOracle.sol";

/**
 * @dev Core of the governance system, designed to be extended through various modules.
 *
 * This contract is abstract and requires several functions to be implemented in various modules:
 *
 * - A counting module must implement {quorum}, {_quorumReached}, {_voteSucceeded} and {_countVote}
 * - Additionally, {votingPeriod} must also be implemented
 */
abstract contract MerkleGovernor is
    Context,
    ERC165,
    EIP712,
    Nonces,
    IMerkleGovernor,
    IERC721Receiver,
    IERC1155Receiver
{
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    bytes32 public constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)");
    bytes32 public constant EXTENDED_BALLOT_TYPEHASH = keccak256(
        "ExtendedBallot(uint256 proposalId,uint8 support,address voter,uint256 nonce,string reason,bytes params)"
    );

    struct ProposalCore {
        address proposer;
        uint48 voteSnapshot;
        uint32 voteDuration;
        bool executed;
        bool canceled;
        bool validated;
        uint48 etaSeconds;
        uint48 proposalTimepoint;
    }

    ICheckpointOracle internal _checkpointOracle;
    address private _proposalValidator;

    bytes32 private constant ALL_PROPOSAL_STATES_BITMAP = bytes32((2 ** (uint8(type(ProposalState).max) + 1)) - 1);
    string private _name;

    mapping(uint256 proposalId => ProposalCore) private _proposals;

    // This queue keeps track of the governor operating on itself. Calls to functions protected by the {onlyGovernance}
    // modifier needs to be whitelisted in this queue. Whitelisting is set in {execute}, consumed by the
    // {onlyGovernance} modifier and eventually reset after {_executeOperations} completes. This ensures that the
    // execution of {onlyGovernance} protected calls can only be achieved through successful proposals.
    DoubleEndedQueue.Bytes32Deque private _governanceCall;

    /**
     * @dev Restricts a function so it can only be executed through governance proposals. For example, governance
     * parameter setters in {GovernorSettings} are protected using this modifier.
     *
     * The governance executing address may be different from the Governor's own address, for example it could be a
     * timelock. This can be customized by modules by overriding {_executor}. The executor is only able to invoke these
     * functions during the execution of the governor's {execute} function, and not under any other circumstances. Thus,
     * for example, additional timelock proposers are not able to change governance parameters without going through the
     * governance protocol (since v4.6).
     */
    modifier onlyGovernance() {
        _checkGovernance();
        _;
    }

    /**
     * @dev Sets the value for {name} and {version}
     */
    constructor(
        string memory name_,
        ICheckpointOracle checkpointOracle_,
        address proposalValidator_
    )
        EIP712(name_, version())
    {
        _name = name_;
        _checkpointOracle = checkpointOracle_;
        _proposalValidator = proposalValidator_;
    }

    /**
     * @dev Function to receive ETH that will be handled by the governor (disabled if executor is a third party contract)
     */
    receive() external payable virtual {
        if (_executor() != address(this)) {
            revert GovernorDisabledDeposit();
        }
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IMerkleGovernor).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IMerkleGovernor-name}.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev See {IMerkleGovernor-version}.
     */
    function version() public view virtual returns (string memory) {
        return "1";
    }

    /**
     * @dev See {IMerkleGovernor-hashProposal}.
     *
     * The proposal id is produced by hashing the ABI encoded `targets` array, the `values` array, the `calldatas` array
     * and the descriptionHash (bytes32 which itself is the keccak256 hash of the description string). This proposal id
     * can be produced from the proposal data which is part of the {ProposalCreated} event. It can even be computed in
     * advance, before the proposal is submitted.
     *
     * Note that the chainId and the governor address are not part of the proposal id computation. Consequently, the
     * same proposal (with same operation and same description) will have the same id if submitted on multiple governors
     * across multiple networks. This also means that in order to execute the same operation twice (on the same
     * governor) the proposer will have to change the description in order to avoid proposal id conflicts.
     */
    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        public
        pure
        virtual
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
    }

    /**
     * @dev See {IMerkleGovernor-state}.
     */
    function state(uint256 proposalId) public view virtual returns (ProposalState) {
        // We read the struct fields into the stack at once so Solidity emits a single SLOAD
        ProposalCore storage proposal = _proposals[proposalId];
        bool proposalExecuted = proposal.executed;
        bool proposalCanceled = proposal.canceled;

        if (proposalExecuted) {
            return ProposalState.Executed;
        }

        if (proposalCanceled) {
            return ProposalState.Canceled;
        }

        bool proposalValidated = proposal.validated;

        if (!proposalValidated) {
            return ProposalState.AwaitingValidation;
        }

        (bytes32 root,, uint256 approvalTimepoint) = _checkpointOracle.getCheckpoint(proposal.voteSnapshot);
        if (root == bytes32(0)) {
            return ProposalState.Pending;
        }

        uint256 currentTimepoint = clock();

        uint256 deadline = approvalTimepoint + _proposals[proposalId].voteDuration;

        if (deadline >= currentTimepoint) {
            return ProposalState.Active;
        } else if (!_quorumReached(proposalId) || !_voteSucceeded(proposalId)) {
            return ProposalState.Defeated;
        } else if (proposalEta(proposalId) == 0) {
            return ProposalState.Succeeded;
        } else {
            return ProposalState.Queued;
        }
    }

    /**
     * @dev See {IMerkleGovernor-proposalSnapshot}.
     */
    function proposalSnapshot(uint256 proposalId) public view virtual returns (uint256) {
        return _proposals[proposalId].voteSnapshot;
    }

    /**
     * @dev See {IMerkleGovernor-proposalDeadline}.
     */
    function proposalDeadline(uint256 proposalId) public view virtual returns (uint256) {
        (,, uint256 approvalTimepoint) = _checkpointOracle.getCheckpoint(_proposals[proposalId].voteSnapshot);

        // Null value
        if (approvalTimepoint == 0) return 0;

        return approvalTimepoint + _proposals[proposalId].voteDuration;
    }

    /**
     * @dev See {IMerkleGovernor-proposalProposer}.
     */
    function proposalProposer(uint256 proposalId) public view virtual returns (address) {
        return _proposals[proposalId].proposer;
    }

    /**
     * @dev See {IMerkleGovernor-proposalEta}.
     */
    function proposalEta(uint256 proposalId) public view virtual returns (uint256) {
        return _proposals[proposalId].etaSeconds;
    }

    /**
     * @dev See {IMerkleGovernor-proposalNeedsQueuing}.
     */
    function proposalNeedsQueuing(uint256) public view virtual returns (bool) {
        return false;
    }

    /**
     * @dev Reverts if the `msg.sender` is not the executor. In case the executor is not this contract
     * itself, the function reverts if `msg.data` is not whitelisted as a result of an {execute}
     * operation. See {onlyGovernance}.
     */
    function _checkGovernance() internal virtual {
        if (_executor() != _msgSender()) {
            revert GovernorOnlyExecutor(_msgSender());
        }
        if (_executor() != address(this)) {
            bytes32 msgDataHash = keccak256(_msgData());
            // loop until popping the expected operation - throw if deque is empty (operation not authorized)
            while (_governanceCall.popFront() != msgDataHash) { }
        }
    }

    /**
     * @dev Amount of votes already cast passes the threshold limit.
     */
    function _quorumReached(uint256 proposalId) internal view virtual returns (bool);

    /**
     * @dev Is the proposal successful or not.
     */
    function _voteSucceeded(uint256 proposalId) internal view virtual returns (bool);

    /**
     * @dev Register a vote for `proposalId` by `account` with a given `support`, voting `weight` and voting `params`.
     *
     * Note: Support is generic and can represent various things depending on the voting system used.
     */
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory params
    )
        internal
        virtual;

    /**
     * @dev Default additional encoded parameters used by castVote methods that don't include them
     *
     * Note: Should be overridden by specific implementations to use an appropriate value, the
     * meaning of the additional params, in the context of that implementation
     */
    function _defaultParams() internal view virtual returns (bytes memory) {
        return "";
    }

    /**
     * @dev See {IMerkleGovernor-requestProposal}. This function has opt-in frontrunning protection, described in {_isValidDescriptionForProposer}.
     */
    function requestProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    )
        public
        virtual
        returns (uint256)
    {
        address proposer = _msgSender();

        // check description restriction
        if (!_isValidDescriptionForProposer(proposer, description)) {
            revert GovernorRestrictedProposer(proposer);
        }

        return _requestProposal(targets, values, calldatas, description, proposer);
    }

    /**
     * @dev Internal propose mechanism. Can be overridden to add more logic on proposal creation.
     *
     * Emits a {IMerkleGovernor-ProposalRequested} event.
     */
    function _requestProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    )
        internal
        virtual
        returns (uint256 proposalId)
    {
        proposalId = hashProposal(targets, values, calldatas, keccak256(bytes(description)));

        if (targets.length != values.length || targets.length != calldatas.length || targets.length == 0) {
            revert GovernorInvalidProposalLength(targets.length, calldatas.length, values.length);
        }
        if (_proposals[proposalId].voteSnapshot != 0) {
            revert GovernorUnexpectedProposalState(proposalId, state(proposalId), bytes32(0));
        }

        uint256 snapshot = clock() + snapshotDelay();
        uint256 duration = votingPeriod();

        ProposalCore storage proposal = _proposals[proposalId];
        proposal.proposer = proposer;
        proposal.voteSnapshot = SafeCast.toUint48(snapshot);
        proposal.voteDuration = SafeCast.toUint32(duration);
        proposal.proposalTimepoint = SafeCast.toUint48(clock() - 1);

        emit ProposalRequested(
            proposalId, proposer, targets, values, new string[](targets.length), calldatas, snapshot, description
        );

        // Using a named return variable to avoid stack too deep errors
    }

    /**
     * @dev Callback function used by centralized party to validate a proposal.
     * Gas is subsidized by the centralized party.
     */
    function validateProposal(
        uint256 proposalId,
        uint256 proposerVotingPower,
        bytes32[] calldata proof
    )
        public
        virtual
    {
        if (_msgSender() != _proposalValidator) revert GovernorOnlyProposalValidator(_msgSender());
        _validateStateBitmap(proposalId, _encodeStateBitmap(ProposalState.AwaitingValidation));

        ProposalCore storage proposal = _proposals[proposalId];
        uint48 proposalTimepoint = proposal.proposalTimepoint;

        (bytes32 merkleRoot,,) = _checkpointOracle.getCheckpoint(proposalTimepoint);

        if (merkleRoot == bytes32(0)) revert GovernorCheckpointNotYetApproved();

        address proposer = proposal.proposer;

        bytes32 leafNode = _efficientHash(proposer, proposerVotingPower);

        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leafNode)) {
            _cancel(proposalId);
            return;
        }

        proposal.validated = true;
        emit ProposalValidated(proposalId);
    }

    /**
     * @dev See {IMerkleGovernor-queue}.
     */
    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        public
        virtual
        returns (uint256)
    {
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);

        _validateStateBitmap(proposalId, _encodeStateBitmap(ProposalState.Succeeded));

        uint48 etaSeconds = _queueOperations(proposalId, targets, values, calldatas, descriptionHash);

        if (etaSeconds != 0) {
            _proposals[proposalId].etaSeconds = etaSeconds;
            emit ProposalQueued(proposalId, etaSeconds);
        } else {
            revert GovernorQueueNotImplemented();
        }

        return proposalId;
    }

    /**
     * @dev Internal queuing mechanism. Can be overridden (without a super call) to modify the way queuing is
     * performed (for example adding a vault/timelock).
     *
     * This is empty by default, and must be overridden to implement queuing.
     *
     * This function returns a timestamp that describes the expected ETA for execution. If the returned value is 0
     * (which is the default value), the core will consider queueing did not succeed, and the public {queue} function
     * will revert.
     *
     * NOTE: Calling this function directly will NOT check the current state of the proposal, or emit the
     * `ProposalQueued` event. Queuing a proposal should be done using {queue}.
     */
    function _queueOperations(
        uint256, /*proposalId*/
        address[] memory, /*targets*/
        uint256[] memory, /*values*/
        bytes[] memory, /*calldatas*/
        bytes32 /*descriptionHash*/
    )
        internal
        virtual
        returns (uint48)
    {
        return 0;
    }

    /**
     * @dev See {IMerkleGovernor-execute}.
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        public
        payable
        virtual
        returns (uint256)
    {
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);

        _validateStateBitmap(
            proposalId, _encodeStateBitmap(ProposalState.Succeeded) | _encodeStateBitmap(ProposalState.Queued)
        );

        // mark as executed before calls to avoid reentrancy
        _proposals[proposalId].executed = true;

        // before execute: register governance call in queue.
        if (_executor() != address(this)) {
            for (uint256 i = 0; i < targets.length; ++i) {
                if (targets[i] == address(this)) {
                    _governanceCall.pushBack(keccak256(calldatas[i]));
                }
            }
        }

        _executeOperations(proposalId, targets, values, calldatas, descriptionHash);

        // after execute: cleanup governance call queue.
        if (_executor() != address(this) && !_governanceCall.empty()) {
            _governanceCall.clear();
        }

        emit ProposalExecuted(proposalId);

        return proposalId;
    }

    /**
     * @dev Internal execution mechanism. Can be overridden (without a super call) to modify the way execution is
     * performed (for example adding a vault/timelock).
     *
     * NOTE: Calling this function directly will NOT check the current state of the proposal, set the executed flag to
     * true or emit the `ProposalExecuted` event. Executing a proposal should be done using {execute} or {_execute}.
     */
    function _executeOperations(
        uint256, /* proposalId */
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 /*descriptionHash*/
    )
        internal
        virtual
    {
        for (uint256 i = 0; i < targets.length; ++i) {
            (bool success, bytes memory returndata) = targets[i].call{ value: values[i] }(calldatas[i]);
            Address.verifyCallResult(success, returndata);
        }
    }

    /**
     * @dev See {IMerkleGovernor-cancel}.
     */
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        public
        virtual
        returns (uint256)
    {
        // The proposalId will be recomputed in the `_cancel` call further down. However we need the value before we
        // do the internal call, because we need to check the proposal state BEFORE the internal `_cancel` call
        // changes it. The `hashProposal` duplication has a cost that is limited, and that we accept.
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);

        // public cancel restrictions (on top of existing _cancel restrictions).
        _validateStateBitmap(proposalId, _encodeStateBitmap(ProposalState.Pending));
        if (_msgSender() != proposalProposer(proposalId)) {
            revert GovernorOnlyProposer(_msgSender());
        }

        return _cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Internal cancel mechanism with minimal restrictions. A proposal can be cancelled in any state other than
     * Canceled, Expired, or Executed. Once cancelled a proposal can't be re-submitted.
     *
     * Emits a {IMerkleGovernor-ProposalCanceled} event.
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        virtual
        returns (uint256)
    {
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);

        _cancel(proposalId);

        return proposalId;
    }

    function _cancel(uint256 proposalId) internal virtual {
        _validateStateBitmap(
            proposalId,
            ALL_PROPOSAL_STATES_BITMAP ^ _encodeStateBitmap(ProposalState.Canceled)
                ^ _encodeStateBitmap(ProposalState.Expired) ^ _encodeStateBitmap(ProposalState.Executed)
        );

        _proposals[proposalId].canceled = true;
        emit ProposalCanceled(proposalId);
    }

    /**
     * @dev See {IMerkleGovernor-castVote}.
     */
    function castVote(
        uint256 proposalId,
        uint8 support,
        uint256 votingPower,
        bytes32[] calldata proof
    )
        public
        virtual
        returns (uint256)
    {
        address voter = _msgSender();
        return _castVote(proposalId, voter, support, votingPower, proof, "");
    }

    /**
     * @dev See {IMerkleGovernor-castVoteWithReason}.
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        uint256 votingPower,
        bytes32[] calldata proof,
        string calldata reason
    )
        public
        virtual
        returns (uint256)
    {
        address voter = _msgSender();
        return _castVote(proposalId, voter, support, votingPower, proof, reason);
    }

    /**
     * @dev See {IMerkleGovernor-castVoteWithReasonAndParams}.
     */
    function castVoteWithReasonAndParams(
        uint256 proposalId,
        uint8 support,
        uint256 votingPower,
        bytes32[] calldata proof,
        string calldata reason,
        bytes memory params
    )
        public
        virtual
        returns (uint256)
    {
        address voter = _msgSender();
        return _castVote(proposalId, voter, support, votingPower, proof, reason, params);
    }

    /**
     * @dev See {IMerkleGovernor-castVoteBySig}.
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        address voter,
        uint256 votingPower,
        bytes32[] calldata proof,
        bytes memory signature
    )
        public
        virtual
        returns (uint256)
    {
        bool valid = SignatureChecker.isValidSignatureNow(
            voter,
            _hashTypedDataV4(keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support, voter, _useNonce(voter)))),
            signature
        );

        if (!valid) {
            revert GovernorInvalidSignature(voter);
        }

        return _castVote(proposalId, voter, support, votingPower, proof, "");
    }

    /**
     * @dev See {IMerkleGovernor-castVoteWithReasonAndParamsBySig}.
     */
    function castVoteWithReasonAndParamsBySig(
        uint256 proposalId,
        uint8 support,
        address voter,
        uint256 votingPower,
        bytes32[] calldata proof,
        string calldata reason,
        bytes memory params,
        bytes memory signature
    )
        public
        virtual
        returns (uint256)
    {
        bytes memory payload = abi.encode(
            EXTENDED_BALLOT_TYPEHASH,
            proposalId,
            support,
            voter,
            _useNonce(voter),
            keccak256(bytes(reason)),
            keccak256(params)
        );

        bool valid = SignatureChecker.isValidSignatureNow(voter, _hashTypedDataV4(keccak256(payload)), signature);

        if (!valid) {
            revert GovernorInvalidSignature(voter);
        }

        return _castVote(proposalId, voter, support, votingPower, proof, reason, params);
    }

    /**
     * @dev Internal vote casting mechanism: Check that the vote is pending,
     * that it has not been cast yet. Voting weight will provided by user and
     * will be proven to be valid using a merkle proof. Then, call the
     * {_countVote} internal function. Uses the _defaultParams().
     *
     * Emits a {IMerkleGovernor-VoteCast} event.
     */
    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 votingPower,
        bytes32[] calldata proof,
        string memory reason
    )
        internal
        virtual
        returns (uint256)
    {
        return _castVote(proposalId, account, support, votingPower, proof, reason, _defaultParams());
    }

    /**
     * @dev Internal vote casting mechanism: Check that the vote is pending,
     * that it has not been cast yet. Voting weight will provided by user and
     * will be proven to be valid using a merkle proof. Then, call the
     * {_countVote} internal function. Uses the _defaultParams().
     *
     * Emits a {IMerkleGovernor-VoteCast} event.
     */
    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 votingPower,
        bytes32[] calldata proof,
        string memory reason,
        bytes memory params
    )
        internal
        virtual
        returns (uint256)
    {
        _validateStateBitmap(proposalId, _encodeStateBitmap(ProposalState.Active));

        (bytes32 root,,) = _checkpointOracle.getCheckpoint(_proposals[proposalId].voteSnapshot);

        bytes32 leafNode = _efficientHash(_msgSender(), votingPower);
        if (!MerkleProof.verifyCalldata(proof, root, leafNode)) {
            revert GovernorInvalidVoterProof(_msgSender(), votingPower);
        }
        _countVote(proposalId, account, support, votingPower, params);

        if (params.length == 0) {
            emit VoteCast(account, proposalId, support, votingPower, reason);
        } else {
            emit VoteCastWithParams(account, proposalId, support, votingPower, reason, params);
        }

        return votingPower;
    }

    /**
     * @dev Relays a transaction or function call to an arbitrary target. In cases where the governance executor
     * is some contract other than the governor itself, like when using a timelock, this function can be invoked
     * in a governance proposal to recover tokens or Ether that was sent to the governor contract by mistake.
     * Note that if the executor is simply the governor itself, use of `relay` is redundant.
     */
    function relay(address target, uint256 value, bytes calldata data) external payable virtual onlyGovernance {
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        Address.verifyCallResult(success, returndata);
    }

    /**
     * @dev Address through which the governor executes action. Will be overloaded by module that execute actions
     * through another contract such as a timelock.
     */
    function _executor() internal view virtual returns (address) {
        return address(this);
    }

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     * Receiving tokens is disabled if the governance executor is other than the governor itself (eg. when using with a timelock).
     */
    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        if (_executor() != address(this)) {
            revert GovernorDisabledDeposit();
        }
        return this.onERC721Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     * Receiving tokens is disabled if the governance executor is other than the governor itself (eg. when using with a timelock).
     */
    function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        if (_executor() != address(this)) {
            revert GovernorDisabledDeposit();
        }
        return this.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     * Receiving tokens is disabled if the governance executor is other than the governor itself (eg. when using with a timelock).
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    )
        public
        virtual
        returns (bytes4)
    {
        if (_executor() != address(this)) {
            revert GovernorDisabledDeposit();
        }
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @dev Encodes a `ProposalState` into a `bytes32` representation where each bit enabled corresponds to
     * the underlying position in the `ProposalState` enum. For example:
     *
     * 0x000...10000
     *   ^^^^^^------ ...
     *         ^----- Succeeded
     *          ^---- Defeated
     *           ^--- Canceled
     *            ^-- Active
     *             ^- Pending
     */
    function _encodeStateBitmap(ProposalState proposalState) internal pure returns (bytes32) {
        return bytes32(1 << uint8(proposalState));
    }

    /**
     * @dev Check that the current state of a proposal matches the requirements described by the `allowedStates` bitmap.
     * This bitmap should be built using `_encodeStateBitmap`.
     *
     * If requirements are not met, reverts with a {GovernorUnexpectedProposalState} error.
     */
    function _validateStateBitmap(uint256 proposalId, bytes32 allowedStates) private view returns (ProposalState) {
        ProposalState currentState = state(proposalId);
        if (_encodeStateBitmap(currentState) & allowedStates == bytes32(0)) {
            revert GovernorUnexpectedProposalState(proposalId, currentState, allowedStates);
        }
        return currentState;
    }

    /*
     * @dev Check if the proposer is authorized to submit a proposal with the given description.
     *
     * If the proposal description ends with `#proposer=0x???`, where `0x???` is an address written as a hex string
     * (case insensitive), then the submission of this proposal will only be authorized to said address.
     *
     * This is used for frontrunning protection. By adding this pattern at the end of their proposal, one can ensure
     * that no other address can submit the same proposal. An attacker would have to either remove or change that part,
     * which would result in a different proposal id.
     *
     * If the description does not match this pattern, it is unrestricted and anyone can submit it. This includes:
     * - If the `0x???` part is not a valid hex string.
     * - If the `0x???` part is a valid hex string, but does not contain exactly 40 hex digits.
     * - If it ends with the expected suffix followed by newlines or other whitespace.
     * - If it ends with some other similar suffix, e.g. `#other=abc`.
     * - If it does not end with any such suffix.
     */
    function _isValidDescriptionForProposer(
        address proposer,
        string memory description
    )
        internal
        view
        virtual
        returns (bool)
    {
        uint256 len = bytes(description).length;

        // Length is too short to contain a valid proposer suffix
        if (len < 52) {
            return true;
        }

        // Extract what would be the `#proposer=0x` marker beginning the suffix
        bytes12 marker;
        assembly {
            // - Start of the string contents in memory = description + 32
            // - First character of the marker = len - 52
            //   - Length of "#proposer=0x0000000000000000000000000000000000000000" = 52
            // - We read the memory word starting at the first character of the marker:
            //   - (description + 32) + (len - 52) = description + (len - 20)
            // - Note: Solidity will ignore anything past the first 12 bytes
            marker := mload(add(description, sub(len, 20)))
        }

        // If the marker is not found, there is no proposer suffix to check
        if (marker != bytes12("#proposer=0x")) {
            return true;
        }

        // Parse the 40 characters following the marker as uint160
        uint160 recovered = 0;
        for (uint256 i = len - 40; i < len; ++i) {
            (bool isHex, uint8 value) = _tryHexToUint(bytes(description)[i]);
            // If any of the characters is not a hex digit, ignore the suffix entirely
            if (!isHex) {
                return true;
            }
            recovered = (recovered << 4) | value;
        }

        return recovered == uint160(proposer);
    }

    /**
     * @dev Try to parse a character from a string as a hex value. Returns `(true, value)` if the char is in
     * `[0-9a-fA-F]` and `(false, 0)` otherwise. Value is guaranteed to be in the range `0 <= value < 16`
     */
    function _tryHexToUint(bytes1 char) private pure returns (bool, uint8) {
        uint8 c = uint8(char);
        unchecked {
            // Case 0-9
            if (47 < c && c < 58) {
                return (true, c - 48);
            }
            // Case A-F
            else if (64 < c && c < 71) {
                return (true, c - 55);
            }
            // Case a-f
            else if (96 < c && c < 103) {
                return (true, c - 87);
            }
            // Else: not a hex char
            else {
                return (false, 0);
            }
        }
    }

    /**
     * @dev Same as keccak256(abi.encodePacked(a, b))
     */
    function _efficientHash(address a, uint256 b) private pure returns (bytes32 result) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            result := keccak256(0x0c, 0x34)
        }
    }

    /**
     * @inheritdoc IERC6372
     */
    function clock() public view virtual returns (uint48);

    /**
     * @inheritdoc IERC6372
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual returns (string memory);

    /**
     * @inheritdoc IMerkleGovernor
     */
    function snapshotDelay() public view virtual returns (uint256);

    /**
     * @inheritdoc IMerkleGovernor
     */
    function votingPeriod() public view virtual returns (uint256);

    /**
     * @inheritdoc IMerkleGovernor
     */
    function quorum(uint256 timepoint) public view virtual returns (uint256);
}
