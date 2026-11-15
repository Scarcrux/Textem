# Controlled native AutoFill consumer

This distinct local app observes an empty `autocomplete=one-time-code` field in
a nonpersistent WKWebView with example.com base context. It is not example.com's
website, a Safari/Chrome compatibility test, or a Textem provider mock. It has no
provider entitlement, shared Keychain access, owner session or cookie store.

Build under the machine's shared native lock:

```sh
lockf -k /tmp/commandem-swift-build.lock bash Experiments/NativeAutoFill/ConsumerTest/build.sh
open -n .build.nosync/native-autofill-consumer/TextemAutoFillConsumer.app --args "$PWD/.build.nosync/native-autofill-consumer/events.jsonl"
```

Before a live test, inspect the current run's private count-only `events.jsonl`:
`control_bad_refused`, `control_good_detected`, then
`ready_empty_controlled_field` with both controls, empty/origin/bounds all1.
Programmatic control values are cleared before LIVE. The compiler treats warnings
as errors, including navigation delegate signature mismatches.

With a fresh real owner-generated dummy SMS imported into the explicitly linked
source, focus the empty consumer field and use macOS AutoFill → Textem Codes →
Fill Code if offered. Do not type or paste the code. Actual OS/provider invocation
and a LIVE matching field are required before claiming a system fill. A matched
CONTROL or populated identity index is not that proof. The consumer never writes
LIVE values, submits a form, accesses Textem's vault or reads actual field values
into its log. Logs contain match/length/trust counts only and separate each run.

The owner's real Textem UI must not be automated when its access is denied;
the owner completes any actual system/provider interaction. Other apps, ordinary
footerless codes and Apple's delivered-code popup remain separate questions.
