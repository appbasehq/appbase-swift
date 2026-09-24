# Swift SDK distribution snapshot

This SDK-only tree was reproducibly exported from Appbase's private source monorepo using `scripts/export-swift-repository.mjs 0.1.0-dev`. The private monorepo remains the source of truth for the SDK, canonical contracts, generated constants and cross-SDK acceptance. Make coordinated changes there and regenerate the export.

Candidate version: `0.1.0-dev`. Candidate archive and package checksums are recorded in the export evidence beside this repository.

The package README is copied unchanged. Development/unpublished installation guidance remains in force until a real public repository and immutable release tag have been published and verified through a fresh remote consumer. Creating this local export or its local verification tag does not publish a release.

Public repository metadata was verified at export time: [https://github.com/appbasehq/appbase-swift](https://github.com/appbasehq/appbase-swift). This export does not configure a Git remote or upload anything.

## Export and verification scope

The allowlist contains `Package.swift`, the library sources, privacy resource, README and license, plus this distribution note, a Git ignore file and standalone CI. Server code, lab apps, credentials and monorepo test fixtures are excluded. Machine-readable checksums and verification evidence are recorded beside this repository in the private export output.

The existing candidate packager verifies a clean local Git-tag consumer and native persistence/workflow APIs before export. The repository wrapper rechecks every candidate file and verifies this exact tree using a fresh external Swift Package Manager consumer and a generic iOS simulator build.

The standalone workflow compiles the package with Xcode 26.1.1 on macOS 15 and for the iOS simulator. It does not run or claim the omitted shared conformance corpus, real HTTP/PostgreSQL checks, interactive native lab, physical-device acceptance or real store purchases. Those gates belong to the private monorepo's release process. A source export does not replace them, and local checks do not establish hosted CI execution.
