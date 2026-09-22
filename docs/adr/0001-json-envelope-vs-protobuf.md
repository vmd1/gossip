# 0001: JSON Envelope vs. Protobuf

## Status

Accepted.

## Context

Connect's wire protocol needs a serialization format for the message envelope exchanged between the Mac (Swift) and Android (Kotlin) apps. The two obvious candidates were a hand-written JSON envelope (`schema/envelope.schema.json`) or a Protocol Buffers (protobuf) schema with generated bindings for both languages.

The two codebases have no shared compiler or build pipeline in Wave 1 — there is no CI step that generates Swift and Kotlin models from a single `.proto` file, and setting one up is itself nontrivial (protoc plugins, build integration on both the Xcode and Gradle sides, versioning of generated code alongside the schema).

## Decision

Use a plain JSON envelope, defined by `schema/envelope.schema.json` and the type registry in `schema/message-types.md`, rather than protobuf, for v1.

Reasons:

- **Faster hand-iteration across two codebases.** Swift's `Codable` and Kotlin's `kotlinx.serialization` both map JSON to native model types with minimal boilerplate, without a code-generation step. Adding or changing a field is a same-PR edit to the registry doc plus two independently-typed model structs — no `.proto` recompilation or generated-code sync required.
- **No shared compiler.** Without a protobuf toolchain wired into both build systems, generated code would need to be committed and manually kept in sync anyway, which erases protobuf's main advantage over hand-written models while keeping its overhead.
- **Trivially debuggable.** JSON frames can be logged, pasted into a bug report, or inspected with `tcpdump`/a debug proxy and read directly by a human, which matters heavily while the protocol itself is still being designed and iterated on across two teams.
- **Message volume/size is not a bottleneck for anything in scope.** Handshake, presence, and trust messages are small and infrequent. The one workload where wire size would matter — screen-mirroring frames — bypasses JSON entirely by design (see `docs/wire-protocol.md`'s large-binary-payload convention), so protobuf's compactness advantage doesn't apply to the case that would actually need it.

## Consequences

- Every envelope pays JSON's text-encoding overhead versus a binary format. Deemed acceptable given the message sizes involved in Wave 1 and its near-term successors.
- Schema evolution is enforced by convention (`schema/message-types.md` + code review) rather than by a schema compiler catching mismatches at build time. Both native codebases must independently keep their `Codable`/`kotlinx.serialization` models in sync with the registry.
- This decision should be revisited if wire size or JSON parsing cost is ever *measured* (not assumed) to be a real bottleneck — at that point, moving specific high-volume message types to a binary format, or adopting protobuf wholesale, are both back on the table.
