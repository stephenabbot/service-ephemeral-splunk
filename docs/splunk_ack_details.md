# Splunk HTTP Event Collector Indexer Acknowledgment

## Overview

HTTP Event Collector (HEC) supports indexer acknowledgment in Splunk Enterprise. This provides confirmation that events have been successfully indexed, not just received.

**Important:** Splunk Cloud Platform supports HEC Indexer Acknowledgment only for AWS Kinesis Firehose.

## Why Use Indexer Acknowledgment

By default, HEC returns HTTP 200 immediately when it receives valid event data, before the event enters the processing pipeline. Events can be lost during processing due to outages or system failures. Indexer acknowledgment provides confirmation that events were actually indexed.

## How It Works

1. Client sends event with channel identifier
2. HEC returns acknowledgment ID (ackId)
3. Client polls acknowledgment endpoint to verify indexing status
4. Client resends events if no acknowledgment received within timeout

## Sending Events with Acknowledgment

### Method 1: Channel as Header

```bash
curl https://mysplunk.com/services/collector \
  -H "X-Splunk-Request-Channel: FE0ECFAD-13D5-401B-847D-77833BD77131" \
  -H "Authorization: Splunk BD274822-96AA-4DA6-90EC-18940FB2414C" \
  -d '{"event": "Hello World"}' \
  -v
```

### Method 2: Channel as Query Parameter

```bash
curl https://mysplunk.com/services/collector?channel=FE0ECFAD-13D5-401B-847D-77833BD77131 \
  -H "Authorization: Splunk BD274822-96AA-4DA6-90EC-18940FB2414C" \
  -d '{"event": "Hello World"}' \
  -v
```

### Response

```json
{"ackId": 0}
```

## Querying Acknowledgment Status

```bash
curl https://mysplunk.com:8088/services/collector/ack?channel=FE0ECFAD-13D5-401B-847D-77833BD77131 \
  -H "Authorization: Splunk BD274822-96AA-4DA6-90EC-18940FB2414C" \
  -d '{"acks":[0,1,2,3]}'
```

**Required Parameters:**
- Channel ID (same as used for sending data)
- Authorization header with HEC token

## Channel Requirements

- **Channel ID Format:** Must be a GUID (Globally Unique Identifier)
- **Generation:** Can be randomly generated
- **Assignment:** One unique channel per client (recommended)
- **Purpose:** Prevents fast clients from impeding slow clients

### Example Channel ID Generation

```bash
# macOS/Linux
uuidgen
# Output: FE0ECFAD-13D5-401B-847D-77833BD77131
```

## Client Behavior Best Practices

An indexer acknowledgment client must:

1. Create its own GUID for channel identifier
2. Send all requests using only that channel
3. Save each ackId returned by HEC
4. Poll `/services/collector/ack` endpoint regularly (e.g., every 10 seconds)
5. Resend event data if no acknowledgment received within timeout (e.g., 5 minutes)
6. Mark resent events as potential duplicates

## Enabling Indexer Acknowledgment

### Via Splunk Web

When creating a HEC token, select the checkbox labeled **Enable indexer acknowledgment**.

### Via inputs.conf

Edit `$SPLUNK_HOME/etc/apps/splunk_httpinput/local/inputs.conf`:

```ini
[http://your-token-name]
useACK = 1
```

Then restart Splunk.

## Raw JSON Endpoint

Indexer acknowledgment also works with raw JSON data using the `/services/collector/raw` endpoint.

## Channel Limits

Configuration settings in `limits.conf` under `[http_input]` stanza:

| Setting | Purpose |
|---------|---------|
| `max_number_of_acked_requests_pending_query_per_ack_channel` | Max ackIds per channel |
| `max_number_of_ack_channel` | Max total channels |
| `max_number_of_acked_requests_pending_query` | Max ackIds across all channels |

Configuration settings in `inputs.conf` under `[http]` stanza:

| Setting | Purpose |
|---------|---------|
| `enableChannelCleanup` | Remove idle channels (true/false) |
| `maxIdleTime` | Seconds before idle channel removal |

## Important Notes

- **Not for Kinesis Firehose:** AWS Kinesis Firehose does not support channel IDs, so indexer acknowledgment cannot be used with Firehose
- **Memory Management:** Splunk caches ackIds in memory; retrieve status regularly to release memory
- **Status Expiration:** Status information is deleted after clients retrieve it
- **Different from Forwarding:** HEC indexer acknowledgment is different from forwarder-based indexer acknowledgment

## Reference

Source: [Splunk Documentation - About HTTP Event Collector Indexer Acknowledgment](https://help.splunk.com/en/splunk-cloud-platform/get-started/get-data-in/10.2.2510/get-data-with-http-event-collector/about-http-event-collector-indexer-acknowledgment)
