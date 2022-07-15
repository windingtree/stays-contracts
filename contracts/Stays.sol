// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.13;

import { Context } from '@openzeppelin/contracts/utils/Context.sol';
import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import { EIP712 } from '@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol';
import { Address } from '@openzeppelin/contracts/utils/Address.sol';
import { SignatureChecker } from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';

import { IServiceProviderRegistry, Role } from '@windingtree/videre-contracts/contracts/interfaces/IServiceProviderRegistry.sol';
import { ILineRegistry } from '@windingtree/videre-contracts/contracts/interfaces/ILineRegistry.sol';
import { LibVidere } from '@windingtree/videre-contracts/contracts/libraries/LibVidere.sol';
import { Vat } from '@windingtree/videre-contracts/contracts/treasury/vat.sol';

import { LibStays } from './LibStays.sol';

/**
 * @title Stays Videre Implementation
 */
contract Stays is Context, EIP712 {

  /// @dev The `deal` lifecycle steps
  enum Step {
    UNINITIALIZED,            // Base state
    INITIAL,                  // Deal is in this state when it’s registered.
                              // This means that both parties agreed
                              // to the terms of the contract.
    CANCELLED_SUPPLIER_GRACE, // The contract may define a “grace period”
                              // within which the supplier may cancel
                              // the deal without any penalties.
                              // For the first version, we recommend
                              // this period to be 30 seconds or so.
    CANCELLED_SUPPLIER,       // Suppliers should be able to cancel
                              // the deal at any time. In this case,
                              // 100% of the deal is refunded to the buyer.
                              // The supplier will have to cover the DAO
                              // and affiliate fees to cancel.
                              // This action will result in a negative
                              // reputation change.
    CANCELLED_BUYER,          // If the deal had an option for the buyer
                              // to cancel, the buyer may invoke it.
                              // These options could be provided
                              // with specified time periods
                              // and refund amounts, or without them.
                              // E.g. an option like that could specify
                              // that the deal may be cancelled “within 15
                              // or more days until the check-in date”
                              // for the “100% amount refunded”.
    CHECKED_IN,               // Both parties have confirmed that
                              // the supplier has started to fulfil
                              // their obligations.
    FULFILLED,                // The contract has been fulfilled successfully
    DISPUTED,                 // The buyer may start a dispute if one of
                              // the final stages of the deal
                              // is not reached (2, 3, 4 or 6).
                              // A dispute may result in two end states:
    RESOLVED_SUPPLIER,        // Dispute is resolved in the supplier favor
    RESOLVED_BUYER            // Dispute is resolved in the buyer favor
  }

  /// @dev `jump` function caller type
  enum Caller {
    UNKNOWN,
    STAFF,
    BIDDER,
    BUYER,
    ADMIN,
    JUDGE
  }

  // --- Auth
  mapping(address => uint256) public wards;

  // --- data
  /// @dev stub id to stub storage
  mapping(bytes32 => LibVidere.StubStorage) public state;
  /// @dev bid id to nonce storage
  mapping(bytes32 => uint256) public nonce;

  /// @dev Videre escrow contract
  Vat public vat;
  /// @dev Service Provider registry
  IServiceProviderRegistry public providers;
  /// @dev Line registry
  ILineRegistry public lines;

  uint256 public live; // Active flag
  bytes32 public immutable line; // The videre line code, eg. "stays"

  /// @dev Allowed transitions table
  mapping(Step => Step[]) internal transitionTable;

  // --- events

  event Deal(bytes32 indexed stubId, bytes32 indexed which);
  event Jump(bytes32 indexed stubId, Step from, Step to);

  // --- modifiers

  modifier auth() {
    require(wards[_msgSender()] == 1, 'Stays/not-authorized');
    _;
  }

  modifier validProvider(bytes32 which) {
    require(lines.can(line, which), 'Stays/provider-not-valid');
    _;
  }

  // --- init
  constructor(
    Vat _vat,
    IServiceProviderRegistry _providers,
    ILineRegistry _lines,
    bytes32 _line,
    string memory _eip712Name,
    string memory _eip712Version
  ) EIP712(_eip712Name, _eip712Version) {
    vat = _vat;
    providers = _providers;
    lines = _lines;
    line = _line;

    wards[_msgSender()] = 1;
    live = 1;

    transitionTable[Step.INITIAL] = [
      Step.CANCELLED_SUPPLIER_GRACE,
      Step.CANCELLED_SUPPLIER,
      Step.CANCELLED_BUYER,
      Step.CHECKED_IN
    ];
    transitionTable[Step.CANCELLED_SUPPLIER_GRACE] = [
      Step.DISPUTED
    ];
    transitionTable[Step.CANCELLED_SUPPLIER] = [
      Step.DISPUTED
    ];
    transitionTable[Step.CANCELLED_BUYER] = [
      Step.DISPUTED
    ];
    transitionTable[Step.CHECKED_IN] = [
      Step.FULFILLED,
      Step.DISPUTED
    ];
    transitionTable[Step.FULFILLED] = [
      Step.DISPUTED
    ];
    transitionTable[Step.DISPUTED] = [
      Step.RESOLVED_SUPPLIER,
      Step.RESOLVED_BUYER
    ];
  }

  function rely(address usr) external auth {
    require(live == 1, 'Stays/not-live');
    wards[usr] = 1;
  }

  function deny(address usr) external auth {
    require(live == 1, 'Stays/not-live');
    wards[usr] = 0;
  }

  // --- admin
  function file(bytes32 what, address data) external auth {
    if (what == 'vat') vat = Vat(data);
    else if (what == 'providers') providers = IServiceProviderRegistry(data);
    else if (what == 'lines') lines = ILineRegistry(data);
  }

  // --- state engine

  /**
   * Execute the deal between service provider and consumer
   *
   * NOTE: This assumes that funds have been joined into the escrow facility already
   *       for `_msgSender()`.
   *
   * TODO #1: Handle EIP712 signatures if dst is different to msg.sender
   * TODO #2: Add support for multiple sigs for EIP712 signing of an approve for collateral joining.
   *
   * @param gem to pay for the deal with
   * @param bid constituting the offer from the service provider to the consumer
   * @param stay deal configuration that hashed in the bid (as params)
   * @param options that have been selected from the bid
   * @param sigs with a minimum of 1 sig from the service provider, 2 if doing EIP712 approval
   * @return stubId the stub id and the typed data hash of the stub state
   */
  function deal(
    address gem,
    LibVidere.Bid memory bid,
    LibStays.Stay memory stay,
    LibVidere.BidOptions memory options,
    bytes[] memory sigs
  ) public payable validProvider(bid.which) returns (bytes32 stubId, bytes32) {
    /// TODO: Make sure stays is a valid line

    /// @dev variable scoping used to avoid stack too deep errors
    ///      `stay` only needs to checked for validity, here and isn't
    //       required further on.
    {
      // make sure the bidder's signature is valid for the provider
      bytes32 bidHash = LibVidere.hash(bid);
      require(
        providers.can(bid.which, Role.BIDDER, ECDSA.recover(_hashTypedDataV4(bidHash), sigs[0])),
        'Stays/invalid-bidder'
      );

      // make sure that the hashed stay match the bid.params
      require(LibStays.hash(stay) == bid.params, 'Stays/invalid-stay');

      // make sure not to exceed the limit
      /// @dev Having a bid limit allows for distribution of free stubs on a
      ///      limited basis, or flow control.
      uint256 bidNonce = ++nonce[bidHash];
      require(bidNonce <= bid.limit, 'Stays/limit-exceeded');

      /// @dev check that the bid sent from the service provider hasn't expired
      require(block.timestamp <= bid.expiry, 'Stays/bid-expired');

      /// @dev generates unique identifier for the stub
      /// TODO: Analyze for hash collision risk
      stubId = label(bidHash, bidNonce);
    }

    /// @dev Stub state for hashing
    LibVidere.StubState memory stubState = LibVidere.StubState({
      which: bid.which,
      params: bid.params,
      items: bid.items,
      terms: bid.terms,
      cost: LibVidere.gemCost(gem, bid.cost)
    });

    /// @dev process any optional items
    if (options.items.length > 0) {
      (stubState.items, stubState.cost) = LibVidere.addOptions(stubState.items, options.items, stubState.cost);
    }

    /// @dev process any optional terms
    if (options.terms.length > 0) {
      (stubState.terms, stubState.cost) = LibVidere.addOptions(stubState.terms, options.terms, stubState.cost);
    }

    /// @dev make the payment here
    vat.deal(stubId, _msgSender(), stubState.cost.gem, stubState.cost.wad, lines.cut(line));

    emit Deal(stubId, stubState.which);

    /// @dev Stub storage
    /// @dev Provides hash collision protection
    LibVidere.StubStorage storage stubStorage = state[stubId];
    require(stubStorage.state == bytes32(0), 'Stays/stub-exists');

    stubStorage.provider = bid.which;
    stubStorage.state = LibVidere.hash(stubState);
    stubStorage.step = uint256(Step.INITIAL);

    emit Jump(stubId, Step.UNINITIALIZED, Step.INITIAL);

    /// @dev store all term links
    for (uint256 i = 0; i < stubState.terms.length; i++) {
      LibVidere.BidTerm memory term = stubState.terms[i];
      stubStorage.terms[term.impl] = term.txPayload;
    }

    return (stubId, stubStorage.state);
  }

  // --- progress to another point in the lifecycle
  /// @param stubId Unique stub Id
  /// @param to Next step
  /// @param stub StubState
  /// @param stay Stay
  /// @param sigs with a minimum of 1 sig from the service provider or buyer
  function jump(
    bytes32 stubId,
    Step to,
    LibVidere.StubState calldata stub,
    LibStays.Stay calldata stay,
    bytes[] calldata sigs
  ) external payable validProvider(stub.which) {
    /// @dev variable scoping used to avoid stack too deep errors
    {
      LibVidere.StubStorage storage stubStorage = state[stubId];
      require(stubStorage.state == bytes32(0), 'Stays/stub-exists');

      Caller calledBy;

      // make sure the stuffs's signature is valid
      bytes32 stubHash = LibVidere.hash(stub);
      // will throw if signature is invalid
      address caller = ECDSA.recover(_hashTypedDataV4(stubHash), sigs[0]);

      if (providers.can(stub.which, Role.STAFF, caller)) {
        calledBy = Caller.STAFF;
      } else if (providers.can(stub.which, Role.BIDDER, caller)) {
        calledBy = Caller.BIDDER;
      } else if (providers.can(stub.which, Role.ADMIN, caller)) {
        calledBy = Caller.ADMIN;
      } else if (vat.owns(stubId) == caller) {
        calledBy = Caller.BUYER;
      }

      // Caller must be known
      require(calledBy != Caller.UNKNOWN, 'Stays/invalid-caller');

      // If caller is a smart contract it must be authorized
      if (Address.isContract(_msgSender())) {
        require(wards[_msgSender()] == 1, 'Stays/not-authorized');
      }

      // make sure the stub is valid state
      require(LibVidere.hash(stub) == stubStorage.state, 'Stays/invalid-stub');

      // make sure that the hashed stay match the stub.params
      require(LibStays.hash(stay) == stub.params, 'Stays/invalid-stay');

      // make sure the next step is not the same as current
      require(to != Step(stubStorage.step), 'Stays/not-allowed');

      // Is transition is allowed in current state
      uint256 transitionAllowed;
      Step[] storage currentStep = transitionTable[Step(stubStorage.step)];

      for (uint256 i = 0; i < currentStep.length; i++) {
        if (currentStep[i] == to) {
          transitionAllowed = 1;
        }
      }

      require(transitionAllowed == 1, 'Stays/not-allowed');

      emit Jump(stubId, Step(stubStorage.step), to);
      stubStorage.step = uint256(to);
    }

    // Step actions

    // Step: CANCELLED_SUPPLIER_GRACE
    // Allowed for: BIDDER
    // - close the deal
    // - refund funds to buyer
    // - emit Cancelled

    // Step: CANCELLED_SUPPLIER
    // Allowed for: ADMIN

    // Step: CANCELLED_BUYER
    // Allowed for: BUYER

    // Step: CHECKED_IN
    // Allowed for: STAFF, BUYER

    // Step: FULFILLED
    // Allowed for: STAFF

    // Step: DISPUTED
    // Allowed for: STAFF, ADMIN, BUYER
  }

  // --- resolve disputed `deal`
  // Can be called by the authorized contract only
  /// @param stubId Unique stub Id
  /// @param to Next step
  function jump(
    bytes32 stubId,
    Step to
  ) external payable auth {
    LibVidere.StubStorage storage stubStorage = state[stubId];

    // make sure that `stub` in allowed state
    require(
      to != Step(stubStorage.step) && Step(stubStorage.step) == Step.DISPUTED,
      'Stays/not-allowed'
    );

    // make sure that the next step is allowed
    require(
      to == Step.RESOLVED_SUPPLIER || to == Step.RESOLVED_BUYER,
      'Stays/not-allowed'
    );

    // Step: RESOLVED_SUPPLIER
    // Allowed for: Authorized contract

    // Step: RESOLVED_BUYER
    // Allowed for: Authorized contract
  }

  // --- helpers

  /// @dev by using _nonce, _msgSender and block.timestamp, one consumer can
  //       make up to the `limit - nonce` deals in one block.
  function label(bytes32 bidHash, uint256 _nonce) internal view returns (bytes32) {
    return keccak256(abi.encode(line, bidHash, _nonce, block.timestamp, _msgSender()));
  }
}
