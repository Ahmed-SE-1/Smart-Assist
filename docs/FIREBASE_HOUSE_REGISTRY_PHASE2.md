# Firebase House Registry Foundation (Phase 2)

## Compatibility

The registry uses the existing owner Firebase Auth UID as `houseId`. It does
not change `users/{uid}`, existing member `houseId` values, MQTT topic roots,
or SharedPreferences room keys. The Firestore House document is stored at
`houses/{houseId}`. `ROOM1_NODE` / `ROOM2_NODE` remain MQTT routing IDs and are
not physical controller or Node identities.

## Registry documents

- `houses/{houseId}`: `houseId`, `ownerUid`, `name`, nullable
  `mainControllerId`, `createdAt`, and `updatedAt`.
- `controllers/{controllerId}`: opaque physical controller identity,
  nullable `activeHouseId`, `status`, `pairedAt`, and `lastSeenAt`.
- `nodes/{nodeId}`: opaque physical Node identity, nullable `controllerId`,
  `houseId`, and `roomId`, `status`, `pairedAt`, and `lastSeenAt`.

Controller and Node models are present, but pairing and registry writes for
those records are intentionally not implemented. Their writes are denied by
the prepared Firestore rules until a trusted pairing operation exists.

## Legacy migration

`HouseService.backfillCurrentOwnerHouse()` handles only the signed-in owner's
legacy profile. It defaults to dry-run. Use `dryRun: false` only as an explicit
operation after reviewing the preview. The method validates `users/{uid}`,
requires `role == owner`, `id == uid`, and `houseId == uid`, then uses a
Firestore transaction and create-only semantics. An existing House document
is left unchanged.

`LegacyHouseMigrationPlanner` is a pure planner for a complete profile scan.
It preserves UID House IDs and reports duplicate owner rows, duplicate
normalized house names, and inconsistent legacy IDs rather than guessing.
No migration runs at app startup. The current rules intentionally permit an
owner to create only their own missing House registry document.

For a complete legacy scan, the trusted callable `migrateLegacyHouses` requires
the out-of-band custom claim `houseMigrationAdmin: true`. It defaults to dry
run; only an explicit `{ "dryRun": false }` request writes, using Admin SDK
transactions and create-only semantics. It reports duplicates/inconsistencies
and leaves existing House documents untouched. This callable is not exposed
as a normal app flow and does not pair devices. Grant the claim only through a
trusted administrative environment, never from Flutter.

## Functions

From the repository root, select the intended Firebase project with
`firebase use --add`. In `functions/`, install dependencies and build with
`npm install` and `npm run build`. Deploy only after reviewing the project and
environment with `firebase deploy --only functions`. An authenticated client
can invoke the `healthCheck` callable; it returns the caller UID and an `ok`
flag and does not pair hardware. Admin SDK access is confined to the trusted
Functions code. No service-account key belongs in Flutter.

## Rules and compatibility notes

`firestore.rules` is configured in `firebase.json` but has not been deployed.
The rules preserve the existing profile creation/index flow, owner member
approval toggle, and owner-only House backfill. Join-code and house-name
lookups are get-only and currently allow unauthenticated reads because the
existing signup flow looks them up before Firebase sign-in. Six-digit join
codes are therefore susceptible to enumeration; migrate signup validation to
a rate-limited callable before treating those codes as a strong security
boundary.

Existing app features read/write rooms, devices, and automations only in
SharedPreferences, so the new Firestore rules do not alter that local behavior.
The actual deployed rules and Firebase Console Auth providers could not be
inspected from this repository. These rules must be reviewed against the live
project and tested in the Firebase Emulator Suite before any manual deployment.
