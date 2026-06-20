# Messaging architecture — hub outbound sends

## Problem statement

Outbound messaging (homeward owner-notify, relay email) runs today as embedded
logic inside laptop-bound daemons. A lost-pet match found while the laptop is
asleep silently drops the notification. This is a real harm: "your dog was
found" is time-sensitive.

**This PRD's fix:** move sends to the always-on hub, triggered by NATS bus
events, so any node in the fleet can queue a message and the hub delivers it.

---

## Send flow

```
                        Fleet NATS bus
                             │
      [laptop / ryzen7]      │                [hub]
      homeward-ingestd  ─────┼──► wm.homeward.match ──► hub-messaging-subscriber
      homeward-reportd  ─────┼──► wm.homeward.reminder    │
                             │                             │
                             │                      message-dedup.sh
                             │                             │
                             │                      (already sent?) ──── yes ──► drop
                             │                             │ no
                             │                      homeward-reportd
                             │                      subscribe-and-send
                             │                             │
                             │                      SMTP / relay API ──► owner's inbox
```

### Detailed steps

1. **Event published** — any fleet node running `homeward-ingestd` or
   `homeward-reportd` detects a new match or reminder and publishes a NATS
   message to `wm.homeward.match` (or `wm.homeward.reminder`).

   Event payload (JSON):
   ```json
   {
     "message_id": "<uuid-or-hash>",
     "pet_id": "shelter-12345",
     "owner_email": "owner@example.com",
     "match_score": 0.93,
     "shelter_name": "City Animal Shelter",
     "contact_url": "https://cityanimals.org/pet/12345"
   }
   ```
   `message_id` is derived from `sha256(pet_id + owner_email + match_date)` so
   retries are naturally idempotent.

2. **Hub subscriber receives event** — `hub-messaging-subscriber.service` runs
   the `homeward-reportd subscribe-and-send` subcommand on the hub. The service
   is gated by `ExecCondition=wm-node role hub` so it only activates on the hub.

3. **Dedup check** — before sending, the subscriber calls `message-dedup.sh
   <message_id>`. The dedup script holds an exclusive `flock` on
   `~/.local/state/homeward/sent-ids.txt` and checks whether the id was already
   recorded. If found → exit 1 (skip). If new → records the id → exit 0.

4. **Send** — `homeward-reportd` reads messaging credentials from
   `~/.config/wintermute/secrets/messaging.env` and issues the outbound send
   (SMTP or relay API POST). The journal log records the message_id and the
   outcome (2xx/accepted or error).

5. **Laptop is unaffected** — even if laptop daemons see the same NATS event,
   `ExecCondition=wm-node role hub` prevents the service from running there.
   The dedup file acts as a belt-and-suspenders guard even if the condition
   were misconfigured.

---

## Idempotency / no-double-send

Two independent guards ensure exactly-once delivery:

| Guard                      | Mechanism                                            | Failure mode if bypassed |
|----------------------------|------------------------------------------------------|--------------------------|
| Role gate                  | `ExecCondition=wm-node role hub` on systemd unit    | Non-hub nodes would also send |
| Message-id dedup           | `flock`-protected `sent-ids.txt`                    | Concurrent or retry sends pass through |

Together they ensure: even if the event fires multiple times (NATS at-least-once
delivery), or if two machines somehow both have the service active, exactly one
send reaches the owner.

### Dedup state file

```
~/.local/state/homeward/sent-ids.txt   (mode 0600)
```

Each line is one `message_id`. The file is append-only and checked via
`grep -qxF`. The `flock` lock file is `sent-ids.txt.lock`.

Entries are never automatically purged (the list is small: ~1 line/match).
If the file grows unexpectedly, prune entries older than 90 days:

```bash
# On hub — keep only entries from the last 90 days
# (requires timestamped format; current format is bare ids — prune manually)
ssh hub "wc -l ~/.local/state/homeward/sent-ids.txt"
```

---

## Adding `wm-node role hub` guard

`wm-node` reads the node role from `/etc/wintermute/node-role` (a single line:
`hub`, `laptop`, `desktop`, etc.). This file is written by the Ansible `cloud`
role during provisioning:

```yaml
# In ansible/roles/cloud/tasks/main.yml:
- name: Set node role to hub
  ansible.builtin.copy:
    content: "hub\n"
    dest: /etc/wintermute/node-role
    mode: "0644"
```

The `wm-node` binary (part of `wintermute/bin/`) checks this file:

```bash
# Exits 0 if role matches, 1 otherwise
wm-node role hub
```

To prevent a laptop from ever sending, ensure `/etc/wintermute/node-role`
contains `laptop` (not `hub`) — set by the `base` Ansible role.

---

## Credentials provisioning

Credentials are managed via the constellation sops/secrets infrastructure.
See [`cloud/secrets/hub-messaging.md`](../secrets/hub-messaging.md) for the
complete provisioning workflow.

Short summary:

1. Create `secrets/cloud/messaging.yaml` with `sops secrets/cloud/messaging.yaml`
2. Ansible decrypts and writes `~/.config/wintermute/secrets/messaging.env` on hub (mode 0600)
3. `hub-messaging-subscriber.service` sources this file via `EnvironmentFile=`

Credentials never touch git as plaintext. Only sops-encrypted ciphertext is
committed.

---

## Operational runbook

### Start / restart the subscriber

```bash
ssh hub "systemctl --user restart hub-messaging-subscriber"
ssh hub "systemctl --user status hub-messaging-subscriber"
```

### Watch live logs

```bash
ssh hub "journalctl --user -u hub-messaging-subscriber -f"
```

### Publish a test event

```bash
# From any node with nats CLI
nats pub wm.homeward.match '{"message_id":"test-001","pet_id":"test","owner_email":"you@example.com","match_score":0.99}' \
    --server nats://hub:4222 --creds ~/.config/nats/creds
```

### Run the full verification suite

```bash
HUB_HOST=hub TEST_RECIPIENT=jyen.tech@gmail.com \
    bash cloud/scripts/verify-messaging.sh
```

### Check dedup state on hub

```bash
ssh hub "wc -l ~/.local/state/homeward/sent-ids.txt"
ssh hub "tail -20 ~/.local/state/homeward/sent-ids.txt"
```

### Force a re-send (clear a specific id from dedup)

```bash
ssh hub "grep -v 'THE-MESSAGE-ID' ~/.local/state/homeward/sent-ids.txt \
    > /tmp/sent-ids.tmp && mv /tmp/sent-ids.tmp ~/.local/state/homeward/sent-ids.txt"
```

---

## Future work

- **Retry + dead-letter queue** — if the SMTP send fails, enqueue in a NATS
  JetStream consumer with exponential back-off rather than dropping the send.
- **Multiple channels** — extend the bus payload to include a `channels` field
  (email, SMS, push) and dispatch per-channel from the subscriber.
- **Rate limiting** — guard against event storms (e.g. 1000 matches/day for a
  viral post) with a per-owner send rate limit.
- **Observability** — emit a `wm.homeward.message_sent` event after each
  successful send for downstream metrics/alerting.
