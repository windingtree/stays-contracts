// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.13;

import {LibVidere} from "@windingtree/videre-contracts/contracts/libraries/LibVidere.sol";

library LibStays {
  // --- constants
  bytes32 private constant STAYS_DEAL_TYPEHASH = keccak256('StaysDeal(bytes32 bid,bytes32 params,address dst)');

  bytes32 private constant DATETIME_TYPEHASH = keccak256('DateTime(uint16 yr,uint8 mon,uint8 day,uint8 hr,uint8 min,uint8 sec)');
  bytes32 private constant STAYS_TYPEHASH = keccak256('Stay(DateTime checkIn,DateTime checkOut,uint32 numPaxAdult,uint32 numPaxChild,uint32 numSpacesReq)DateTime(uint16 yr,uint8 mon,uint8 day,uint8 hr,uint8 min,uint8 sec)');

  // --- eip712 signatures for gasless execution
  function hashStaysDeal(
    bytes32 bid,
    bytes32 params,
    address dst
  ) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(
        STAYS_TYPEHASH,
        bid,
        params,
        dst
      )
    );
  }

  // --- eip712 signatures for data exchange

  /// @dev use of non-standard / shorthand due 'seconds' being a reserved word
  struct DateTime {
    uint16 yr;
    uint8 mon;
    uint8 day;
    uint8 hr;
    uint8 min;
    uint8 sec;
  }

  function hash(DateTime memory a) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(
        DATETIME_TYPEHASH,
        a.yr,
        a.mon,
        a.day,
        a.hr,
        a.min,
        a.sec
      )
    );
  }

  // --- stay state

  struct Stay {
    DateTime checkIn;
    DateTime checkOut;
    uint32 numPaxAdult;
    uint32 numPaxChild;
    uint32 numSpacesReq;
  }

  function hash(Stay memory a) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(
        STAYS_TYPEHASH,
        hash(a.checkIn),
        hash(a.checkOut),
        a.numPaxAdult,
        a.numPaxChild,
        a.numSpacesReq
      )
    );
  }

  function decodeStay(bytes memory payload) internal pure returns (Stay memory decoded) {
    decoded = abi.decode(payload, (Stay));
  }

  function decodeDateTime(bytes memory payload) internal pure returns (DateTime memory decoded) {
    decoded = abi.decode(payload, (DateTime));
  }
}