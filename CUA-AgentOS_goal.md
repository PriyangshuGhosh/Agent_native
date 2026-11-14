# CUA-AgentOS: Product Goal, Architecture Direction, and Implementation Roadmap

**Document type:** Engineering direction for Claude-assisted
development\
**Project:** CUA-AgentOS / Agent_native\
**Initial target:** Raspberry Pi 5, ARM64\
**Status:** Direction and requirements proposal; verify all
implementation claims against the repository before changing code.

------------------------------------------------------------------------

## 1. Product vision

Build a stable, general-purpose Linux distribution in which a user can
operate and maintain the computer primarily through natural-language
requests, without needing to use a terminal, keyboard, or mouse for
routine tasks.

The user should be able to ask the system to perform work, configure
applications, diagnose supported problems, maintain the OS, and recover
from common failures. The OS and agent should carry out those tasks,
verify their results, and explain what changed.

The product is **not** merely a chatbot, a GUI macro tool, or a Linux
desktop with an AI application installed. The goal is an
**agent-operated Linux environment** in which AI planning is integrated
with reliable, bounded operating-system capabilities.

### Product promise

A user states the desired outcome. The system: 1. Understands the
request and checks whether it is supported. 2. Creates a plan using
available, documented capabilities. 3. Checks permissions, risk, and
preconditions. 4. Executes operations through controlled interfaces. 5.
Independently verifies whether the intended result was achieved. 6.
Recovers or rolls back when safe and possible. 7. Reports the result,
any changes made, and any unresolved issue.

The system must not claim success merely because a command ran or an API
returned successfully.

## 2. Design principles

These principles should guide architecture and implementation decisions.

### 2.1 Reuse Linux; innovate above it

**Recommendation:** Do not rebuild the Linux kernel, device drivers,
networking stack, package-management ecosystem, or other mature OS
infrastructure without a concrete requirement that existing components
cannot satisfy.

Use a minimal, maintained Linux base that supports the target hardware.
Build the agent-native operating environment, policies, system-operation
interface, recovery mechanisms, and user experience as the project's
differentiating layer.

Debian or a Debian-derived minimal ARM64 base is a reasonable starting
point for Raspberry Pi 5 because hardware support and established system
tooling are important to this project. Before committing, compare boot
requirements, image size, update strategy, package availability,
licensing, security maintenance, and compatibility with the current
implementation.

Do not migrate the project blindly. First inspect the existing build,
init system, root filesystem, service model, package tooling, and boot
flow. Propose a migration only after documenting the benefits, risks,
and work involved.

### 2.2 Keep the system core deterministic

The AI model must not be responsible for keeping the machine bootable or
for enforcing its own permissions.

The non-AI system core must be able to: - Boot and supervise essential
processes. - Keep a usable local status or recovery interface
available. - Enforce permissions and resource limits. - Record system
changes. - Reject malformed, unauthorized, or unsafe requests. - Recover
from agent crashes, model errors, network outages, and failed
operations.

If the model is unavailable, the OS must remain usable and must not
enter a restart loop.

### 2.3 Treat the model as an untrusted planner

Model output is a proposal, not authority.

The model must not receive unrestricted root shell access. It should
request typed operations from a privileged system broker. The broker
must validate the operation, arguments, permissions, preconditions,
resource limits, and risk independently of the model.

Never treat model-generated explanations as proof that an operation
succeeded.

### 2.4 Verify outcomes, not just actions

Every supported task needs an explicit success condition. After
executing an operation, the system should check the actual resulting
state using an appropriate independent signal.

Examples: - Restarting a service is not success unless the service
reaches the required healthy state. - Changing network configuration is
not success unless connectivity is tested. - Installing an application
is not success unless installation and basic launch checks pass. -
Repairing a system setting is not success if the original failure
remains.

### 2.5 Prefer reversible changes

Use staged changes, transactions, snapshots or checkpoints where
appropriate, validation before activation, and rollback when safe.
Record enough information to explain what changed and to recover from
interrupted operations.

Not every action can be rolled back. For irreversible or high-impact
operations, the system must warn the user and obtain the required
approval before execution.

### 2.6 Keep the interface simple; keep the internals observable

The user should not need a terminal for normal tasks. Developers must
still have logs, structured diagnostics, test hooks, and a recovery
path. A no-terminal user experience must not mean an unobservable or
un-debuggable system.

### 2.7 Prefer narrow, testable capabilities over unrestricted autonomy

Add capabilities incrementally. Each capability should define: - Its
input schema and validation rules. - Required permissions. -
Preconditions and expected postconditions. - Time and resource limits. -
Failure modes and recovery behavior. - Audit events. - Automated tests.

Do not advertise a capability as supported until it passes tests on the
intended runtime.

------------------------------------------------------------------------

## 3. Scope and non-goals

### In scope

-   A custom Linux distribution or minimal Linux-based operating
    environment.
-   Raspberry Pi 5 ARM64 as the first physical target.
-   Natural-language interaction for routine computing and system
    administration.
-   A reliable boot and service-supervision path.
-   Controlled interfaces for system and application operations.
-   Health monitoring, fault diagnosis, safe repair, and recovery.
-   Persistent user preferences and task history, with explicit privacy
    boundaries.
-   Operation with a cloud model or a local model where supported.
-   Automated testing, fault injection, reproducible builds, and
    hardware validation.

### Not an initial requirement

-   Replacing the Linux kernel.
-   Reimplementing standard drivers or package managers.
-   Supporting every Linux application or every possible user task.
-   Fully autonomous execution of destructive or security-sensitive
    actions.
-   Depending on a cloud model for boot, basic OS operation, or
    emergency recovery.
-   Claiming production readiness based only on a successful emulator
    boot or a custom rubric score.

The first release should support a small, clearly defined set of useful
workflows reliably rather than a large set unreliably.

------------------------------------------------------------------------

## 4. Target user experience

### 4.1 Normal interaction

The user can submit a request through a simple interface. Text is the
first practical interface; voice can be added after the core task loop
is reliable.

Illustrative requests: - "Tell me why the network is not working and try
a safe repair." - "Install this supported application and confirm that
it opens." - "Free up disk space, but show me what you intend to remove
first." - "Check whether the system is healthy." - "Undo the last system
change because the problem started afterward."

These are examples of intended behavior, not claims that the current
repository already supports them.

### 4.2 Expected response

For each task, the user should be able to see: - What the agent
understood. - What it intends to do, when preview or approval is
appropriate. - Which operations were performed. - Whether the
postconditions passed. - Which changes were made. - Whether a rollback
occurred. - What remains unresolved and why.

Use plain language. Technical details should be available on demand
rather than forced on every user.

### 4.3 No keyboard or mouse for routine use

The system should not require manual terminal commands or GUI
manipulation for supported workflows. However, retain a protected
emergency recovery route. A stable OS must remain recoverable even when
the model, audio stack, network, or normal interface fails.

Voice must not be the only access method. Provide at least one
alternative interaction path, such as text or a local status/recovery
screen.

------------------------------------------------------------------------

## 5. Proposed architecture

This is a target architecture, not a statement that all components
currently exist. Map it against the repository before implementation.

### 5.1 Linux foundation

Responsibilities: - Kernel and device drivers. - Bootloader and ARM64
boot configuration. - Filesystems and storage. - Networking and device
management. - User and group identities, access controls, and process
isolation. - Package installation and system update mechanisms.

**Recommendation:** Use mature components wherever practical. Keep
custom code focused on agent-specific policy, orchestration, operations,
and recovery.

### 5.2 Minimal system supervisor / init

Responsibilities: - Start essential services in a defined order. - Reap
child processes and handle shutdown correctly. - Supervise critical
services and apply bounded restart policies. - Provide a recovery or
degraded mode. - Avoid making successful AI startup a prerequisite for a
usable OS.

The current repository contains an `agent-init` implementation according
to project history. Inspect its actual behavior and tests before
deciding whether to keep it as PID 1 or move to a conventional init
system. A custom PID 1 adds responsibility: signal handling, child
reaping, shutdown semantics, service supervision, and failure recovery
must be tested carefully.

Do not retain custom init merely for novelty. Keep it only if it
provides measurable value and can meet the reliability burden.

### 5.3 Agent daemon / orchestrator

Responsibilities: - Interpret user intent. - Produce structured plans. -
Select among registered capabilities. - Track task state and
deadlines. - Ask for missing information or approval. - Execute through
the broker. - Verify postconditions. - Retry only when safe and
bounded. - Choose rollback or escalation when recovery fails.

The daemon should not directly bypass the broker to perform privileged
actions.

### 5.4 Privileged system broker

A proposed component and a high priority.

Expose narrow, typed operations rather than a general root shell.
Examples of possible future capabilities: - Query system health. - Read
selected logs and service status. - Restart an allowlisted service. -
Apply a validated network configuration. - Install an approved
package. - Stage and activate a system update. - Restore a known-good
configuration checkpoint.

Each operation needs a schema, permission policy, preconditions,
postconditions, timeout, audit record, and failure behavior.

The broker must reject unknown operations, invalid arguments, path
traversal, privilege escalation attempts, and calls outside its policy.
The model must not be able to rewrite the broker's policy or grant
itself new permissions.

### 5.5 Health monitor

A proposed component.

Monitor measurable conditions such as: - Essential service health. -
Free storage and memory pressure. - Network connectivity. - Failed or
interrupted updates. - Repeated crashes and restart loops. - Temperature
and throttling on supported hardware.

Use deterministic checks for detection where possible. Use the model to
interpret evidence and select among permitted recovery procedures, not
to replace health checks.

Monitoring should avoid unnecessary polling, excessive logging, and
continuous model calls.

### 5.6 Transaction and recovery manager

Responsibilities: - Record intended and completed changes. - Keep a
durable transaction journal. - Detect incomplete transactions after a
crash or power loss. - Validate staged changes before activation. -
Support rollback for operations designed to be reversible. - Preserve
audit records without storing unnecessary secrets.

A read-only base with a writable overlay, immutable image, or A/B update
design may be appropriate, but choose the storage model based on
measured needs and hardware constraints. Verify persistence and crash
behavior on the actual device.

Do not claim rollback guarantees for data or actions that cannot
actually be restored.

### 5.7 User interface

Responsibilities: - Receive text and, later, voice requests. - Display
task progress and approvals. - Explain results and unresolved
failures. - Offer an emergency status/recovery route. - Remain usable
when the model provider is offline.

Keep the interface decoupled from the agent's privileged execution path.
A UI compromise must not grant system privileges.

### 5.8 Model provider adapter

Support a clear boundary between orchestration and inference. The
provider can be cloud-hosted or local, depending on device resources and
configuration.

Requirements: - Timeouts and bounded retries. - Explicit handling of
authentication errors, rate limits, malformed output, and
disconnection. - Structured output validation. - No secrets in prompts
or logs unless strictly necessary. - No model dependency for boot,
permission enforcement, or rollback. - Graceful degraded behavior when
inference is unavailable.

Do not assume the Raspberry Pi 5 can run a particular model at an
acceptable speed without measurement.

------------------------------------------------------------------------

## 6. The standard task lifecycle

Implement one shared lifecycle for supported tasks instead of separate,
inconsistent execution logic.

1.  **Receive:** Accept the user request and create a task ID.
2.  **Interpret:** Convert the request into a structured goal; ask for
    clarification if essential details are missing.
3.  **Plan:** Produce a bounded plan using registered capabilities.
4.  **Classify risk:** Determine permissions, reversibility, impact, and
    whether approval is required.
5.  **Validate:** Check argument schemas, preconditions, available
    resources, and policy.
6.  **Execute:** Run one operation at a time through the appropriate
    capability.
7.  **Observe:** Collect actual system state and operation results.
8.  **Verify:** Evaluate explicit postconditions independently of the
    model's narrative.
9.  **Recover:** Retry only when safe; otherwise roll back or stop and
    request assistance.
10. **Report:** Summarize outcome, changes, evidence, and remaining
    uncertainty.
11. **Persist:** Store the minimum useful task history and audit
    information according to the retention policy.

Each task needs a deadline, cancellation semantics, and a maximum number
of retries or replanning attempts. Prevent infinite repair loops.

------------------------------------------------------------------------

## 7. Safety and permission model

Safety must be enforced by code, not by prompting the model to behave
responsibly.

### 7.1 Risk tiers

Use a small explicit policy model. The exact classification should be
defined in code and tests.

-   **Low risk:** Read-only health checks and queries over approved
    data. May run automatically.
-   **Moderate risk:** Reversible configuration changes or restarting an
    allowlisted service. May run automatically only when policy,
    preconditions, and rollback requirements are satisfied.
-   **High risk:** Removing data, changing security policy, modifying
    boot configuration, installing untrusted software, or changing user
    credentials. Require explicit approval or disallow in the initial
    release.
-   **Prohibited:** Actions that bypass the policy engine, grant the
    model unrestricted privileges, disable essential safety controls, or
    destroy recovery mechanisms.

### 7.2 Required controls

-   Least-privilege service identities.
-   Narrow allowlists and typed operations.
-   Input and path validation.
-   Process, memory, CPU, and time limits where appropriate.
-   Isolation for untrusted code and applications.
-   Durable audit records.
-   Cancellation and emergency-stop behavior.
-   Protection against repeated or conflicting operations.
-   Approval for high-impact changes.
-   Recovery from broker, daemon, model, and UI failure.

A list of allowed command names is not sufficient isolation on its own.
Use operating-system security boundaries appropriate to the chosen base.

### 7.3 Secrets and privacy

-   Do not expose API keys, passwords, tokens, or private files to the
    model unnecessarily.
-   Keep credentials out of logs and task summaries.
-   Make it clear which information may be sent to a cloud model.
-   Minimize retained conversation and telemetry data.
-   Provide a way to inspect and delete locally stored task history
    where supported.

------------------------------------------------------------------------

## 8. Reliability requirements

Treat these as acceptance requirements to implement and test, not as
already achieved properties.

### Boot and service lifecycle

-   Essential services start in a deterministic order.
-   A failed model provider does not block OS startup.
-   A crashed agent daemon can be restarted without rebooting the whole
    system.
-   Restart policies prevent endless crash loops.
-   The system has a documented degraded mode and recovery path.

### Operations

-   Every capability validates inputs and permissions.
-   Every modifying operation defines postconditions.
-   Timeouts and cancellation are handled.
-   Interrupted transactions are detected at the next boot.
-   Failed reversible operations restore the previous known-good state
    when possible.
-   The system never reports success without evidence.

### Storage and updates

-   User data persistence is explicitly defined and tested.
-   Power loss during an update or transaction is tested.
-   Updates are staged and validated before becoming the active system.
-   A known-good recovery path remains available.
-   Package versions and build inputs are pinned or otherwise made
    reproducible where practical.

### Offline behavior

-   The system boots and remains manageable without cloud inference.
-   Local health checks and recovery procedures continue to work.
-   The UI explains when a task requires an unavailable model or network
    connection.

### Hardware

-   Validate on physical Raspberry Pi 5 hardware, not only QEMU.
-   Test keyboard and mouse detection as diagnostics, but do not treat
    their detection as proof of a usable UI.
-   Test display, networking, USB, storage, shutdown, reboot, and
    recovery.
-   Measure RAM, CPU, temperature, storage use, boot time, and task
    latency.

------------------------------------------------------------------------

## 9. Development plan: implement in small, verifiable chunks

Claude should work incrementally. Do not implement the entire
architecture in one large change.

### Chunk 0 --- Repository audit and source of truth

Before editing: 1. Inspect the current repository, build scripts,
documentation, tests, and recent commits. 2. Identify implemented,
partially implemented, mocked, fixture-driven, and unimplemented
behavior. 3. Trace the real boot path from image creation through kernel
startup, PID 1, service startup, agent daemon, and UI. 4. Check whether
documented persistence, rollback, provider integration, and security
features match the code. 5. Run the relevant existing tests and record
exact results. 6. Produce a concise gap report with file paths and
evidence.

Do not infer implementation from filenames, plans, comments, or
documentation alone.

**Deliverable:** an evidence-based implementation map and prioritized
gap list. Do not start a broad refactor in this chunk.

### Chunk 1 --- Reliable boot and degraded mode

Goals: - Establish explicit boot states and service dependencies. -
Verify PID 1 and child-process handling. - Start essential services
reliably. - Ensure model/API failure cannot block the system. - Add
bounded service restart behavior and a recovery path. - Provide useful
boot and service diagnostics.

Tests: - Normal boot. - Agent daemon missing or crashing. - Model
provider unavailable. - Essential service failure. - Repeated crash
without restart loop. - Clean shutdown and reboot.

**Exit criterion:** the system reaches a defined usable or recovery
state in each tested scenario.

### Chunk 2 --- Minimal user interaction

Goals: - Provide a basic text interface and clear status display. - Send
a request to the agent daemon through a documented interface. - Display
task progress, approval requests, results, and errors. - Keep the
interface usable without a cloud model.

Do not start with voice, a sophisticated desktop, or broad GUI
automation.

**Exit criterion:** a user can submit a request, follow its status, and
understand the result without using a terminal.

### Chunk 3 --- One end-to-end task

Choose one low-risk task with a clear success condition, such as
inspecting system health and explaining a detected issue.

Implement the complete task lifecycle, including structured plan
validation, execution, independent verification, timeout, cancellation,
and reporting.

**Exit criterion:** the task succeeds on the actual target system, and
injected failures are handled correctly.

### Chunk 4 --- Privileged broker and permission enforcement

Introduce the typed broker before expanding system-changing
capabilities.

Implement: - Operation registry and schemas. - Independent authorization
and argument validation. - Least-privilege execution. - Timeouts and
resource limits. - Audit events. - Explicit approval for high-risk
actions. - Tests proving the model cannot bypass the broker.

**Exit criterion:** unauthorized and malformed operations are rejected
by the system, regardless of the model's instructions.

### Chunk 5 --- Transactions and recovery

Start with one reversible system operation. Add a durable journal,
recovery after interruption, postcondition checks, and rollback.

Then test process termination and power interruption at relevant
transaction stages. Expand to package or system updates only after the
mechanism is proven.

**Exit criterion:** the recovery behavior is reproducible and
documented; unsupported rollback claims are removed.

### Chunk 6 --- Health monitoring and limited repair

Add a small set of deterministic health checks. Connect each supported
fault to a bounded, documented remediation procedure. Use the model for
diagnosis and selection, but keep the execution policy in code.

**Exit criterion:** a fault-injection suite shows detection, safe
remediation or rollback, and truthful reporting.

### Chunk 7 --- Physical Pi 5 validation

Create a repeatable test procedure for clean installation, boot,
restart, networking, input/output, storage persistence, offline
behavior, agent tasks, and recovery.

Record exact image/build identifiers, hardware, test steps, logs,
resource measurements, and failures.

**Exit criterion:** results can be reproduced on a physical Pi 5.
Emulator results must be labeled separately.

### Chunk 8 --- Expand capabilities cautiously

Only after the preceding chunks pass: - Add package installation and
application management. - Add selected GUI automation. - Add voice
input/output if useful. - Evaluate local inference against cloud
inference. - Add user preferences and persistent task history with
privacy controls. - Broaden supported hardware only with a defined test
matrix.

**Exit criterion:** each new capability has tests, permissions,
verification, and a recovery policy.

------------------------------------------------------------------------

## 10. Testing and evaluation

A custom build score or successful boot is not a substitute for
end-to-end task reliability.

Maintain separate test categories:

1.  **Build tests:** image creation, pinned inputs, reproducibility.
2.  **Boot tests:** kernel, init, service lifecycle, shutdown and
    recovery.
3.  **Unit tests:** schemas, policy checks, transaction logic and state
    transitions.
4.  **Integration tests:** agent daemon, broker, services and UI.
5.  **Task tests:** real requests with independently checked
    postconditions.
6.  **Fault-injection tests:** crashes, network loss, malformed model
    output, disk pressure, interrupted operations and failed updates.
7.  **Hardware tests:** physical Pi 5 behavior, thermals, memory,
    storage and peripherals.
8.  **Security tests:** privilege boundaries, unauthorized operations,
    malicious arguments and attempted policy bypass.

For every task benchmark, record: - Task description and initial
state. - Expected final state. - Whether approval is required. -
Success/failure judged from system state. - Time to completion. - Number
of model calls and retries. - Resource use where practical. - Whether
recovery or rollback was needed. - Any unsafe or unauthorized operation
attempted.

Do not report a task as successful based only on the agent's own final
message.

Start with a small benchmark of representative tasks. Increase coverage
only after the test definitions and evaluation method are stable.

------------------------------------------------------------------------

## 11. Definition of a credible first release

The first release should not claim to automate all computer use or all
Linux maintenance.

A credible initial release should demonstrate all of the following:

-   A reproducible ARM64 image boots on a physical Raspberry Pi 5.
-   Essential services start without manual terminal intervention.
-   The system remains usable when AI inference is unavailable.
-   A natural-language interface can run a small set of documented
    tasks.
-   Privileged actions pass through an independently enforced policy
    layer.
-   At least one modifying task has a tested verification and recovery
    path.
-   Repeated boot, restart, and fault-injection tests pass with recorded
    evidence.
-   User data persistence and update behavior are documented and tested.
-   The project clearly distinguishes implemented capabilities from
    planned ones.

Production readiness requires more security review, long-duration
testing, update maintenance, and hardware coverage than this initial
milestone.

------------------------------------------------------------------------

## 12. Recommendations and trade-offs

### Recommendation A --- Use a mature Linux base

Prefer a minimal maintained base over rebuilding standard OS
infrastructure. Evaluate Debian or a Debian-derived base for the Pi 5.
Keep the agent-specific architecture independent of unnecessary
distribution details.

**Reason:** driver support, security updates, package availability, and
maintainability matter more than owning every layer.

### Recommendation B --- Audit before migrating

The current project already contains custom OS and agent-runtime work.
Do not discard it based on a general recommendation. Determine what is
sound, what is experimental, and what is expensive to maintain. Migrate
only where evidence supports the change.

### Recommendation C --- Prioritize deterministic recovery over broader autonomy

A narrow agent that can reliably diagnose and fix a few problems is more
useful than a broad agent that occasionally leaves the system broken.

### Recommendation D --- Keep model access outside the trust boundary

The model should propose actions. The broker and OS enforce what is
allowed. This separation is fundamental, not a future enhancement.

### Recommendation E --- Treat hardware validation as a required engineering stage

A successful QEMU run is useful but does not prove that the image works
reliably on the Pi 5. Validate the real boot, display, networking,
storage, shutdown, and recovery paths.

### Recommendation F --- Keep the project honest and measurable

Use explicit statuses such as `implemented`, `partial`, `mocked`,
`not tested on hardware`, and `planned`. Do not let a roadmap item
become a claimed feature without evidence.

------------------------------------------------------------------------

## 13. Instructions for Claude when working in this repository

Use this document as product direction, not as evidence that a feature
exists.

For each implementation task:

1.  Inspect the relevant source files and existing tests first.
2.  State the current behavior and cite exact file paths or symbols.
3.  Identify the smallest change that advances one milestone.
4.  Explain the proposed design briefly, including relevant failure
    modes.
5.  Implement only the requested chunk; avoid unrelated refactors.
6.  Add or update tests alongside the implementation.
7.  Run the narrowest relevant tests first, then broader tests when
    feasible.
8.  Report exact commands and results. Never claim tests passed if they
    were not run.
9.  Identify tests that require physical Pi 5 hardware and do not
    substitute emulator success for hardware validation.
10. Update documentation to match actual behavior.
11. Call out contradictions between code, tests, generated reports, and
    documentation.
12. Do not invent APIs, files, service behavior, benchmarks, or
    successful results.
13. If a requirement is ambiguous or the current architecture creates a
    significant trade-off, explain the options and recommend one before
    making a large change.
14. Preserve working functionality unless the change explicitly replaces
    it.
15. Finish each chunk with: changed files, behavior added, tests run,
    results, known limitations, and the next smallest recommended step.

Prefer small, reviewable commits. Do not combine base-distribution
migration, init-system redesign, model integration, UI work, and
security redesign into one change.

------------------------------------------------------------------------

## 14. The next action

Begin with **Chunk 0: Repository audit and source of truth**.

Do not start by rewriting the OS or adding more features. First
establish, from the current repository and actual test results:

-   What boots today.
-   Which process is PID 1 on the physical Pi 5.
-   Which services start and in what order.
-   Whether the agent daemon is actually running.
-   Whether model responses are live or fixture-driven.
-   Which operations execute against the real OS.
-   Which safety and rollback mechanisms are implemented and tested.
-   What persists across reboot.
-   Which claims have been verified on physical hardware.

Then recommend the smallest next change that advances the first
acceptance criterion.

## Final product definition

**CUA-AgentOS is a Linux-based operating environment designed to let
users operate and maintain their computer through natural-language
intent. It combines an AI planning layer with constrained system
capabilities, independent outcome verification, and recoverable
execution. The underlying OS must remain safe, observable, and usable
when the AI fails or is unavailable.**

The project's success should be measured by reliable, verified tasks and
safe recovery on real hardware---not by the number of AI features, the
amount of custom code, or the appearance of autonomy.
