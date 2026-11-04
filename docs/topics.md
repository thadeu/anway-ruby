# Topics

A topic sends one event to many queues. `publish` makes one job for each subscription of the topic, in one transaction on the server. Each copy is a normal job in the queue of its subscriber, with its own retries, Dead set, throttle, and autoscale.

The server holds the rule. [topics.md](https://github.com/thadeu/anway/blob/main/docs/dev/topics.md) in the server repo explains it in full. Topics need server v0.3.0 or later.

## Example: one chat message, three apps

A chat app publishes each message one time. Three apps each get their own copy:

```text
publisher               server, in one transaction                     subscribers
---------               --------------------------                     -----------
publish chat.message ─┬─> queue realtime,  job BroadcastMessage ──> app A: realtime
                      ├─> queue cassandra, job StoreMessage     ──> app B: Cassandra
                      └─> queue push,      job NotifyMessage    ──> app C: push notifications
```

If the Cassandra app stops for ten minutes, its copies wait in its queue. The other apps continue.

### Publish the event

```ruby
Anway.publish('chat.message', [{ 'room' => 'general', 'body' => 'hi' }], id: 'msg-42')
# => #<data Anway::Client::Published event="msg-42", jobs=3, duplicate=false>
```

### Subscribe in each app

App A, the realtime app:

```ruby
class BroadcastMessage
  include Anway::Worker

  anway_options topics: %w[chat.message], queue: 'realtime'

  def perform(message)
    ChatChannel.broadcast_to(message['room'], message)
  end
end
```

App B, the Cassandra app:

```ruby
class StoreMessage
  include Anway::Worker

  anway_options topics: %w[chat.message], queue: 'cassandra', retry: 10

  def perform(message)
    Messages.insert(message)
  end
end
```

App C, the push app:

```ruby
class NotifyMessage
  include Anway::Worker

  anway_options topics: %w[chat.message], queue: 'push', reserve_for: 60

  def perform(message)
    PushNotification.deliver(message)
  end
end
```

Start the worker of each app with `bundle exec anway`. Each worker sends `SUBSCRIBE` for its classes before its first fetch. Then each app runs one copy of every message.

## Publish

```ruby
Anway.publish(topic, args = [], id: nil, unique_for: nil, custom: nil)
client.publish(topic, args = [], id: nil, unique_for: nil, custom: nil)
```

- `args` is an array, as in a job. Every copy gets the same args. Args must be JSON types with string hash keys. Other values raise `ArgumentError` before the gem sends the event.
- `id` is the event id. With an id, a second publish of the same topic and id within `unique_for` seconds makes no job, and the reply has `duplicate: true`. The default of `unique_for` is 86,400 seconds (one day). Set `unique_for: 0` to turn off the check.
- Without an id, the server makes one, such as `evt-…`. There is no duplicate check.
- `custom` goes to each copy. The server adds `topic` and `event` to it.
- The reply is an `Anway::Client::Published`, with `event`, `jobs` (the number of copies), and `duplicate`.

`Anway.publish` uses the shared client. Inside a database transaction, it waits for the commit and returns `nil`. A rollback cancels it.

## Subscribe

### In a job class

```ruby
anway_options topics: %w[chat.message]                                       # all defaults
anway_options topics: %w[chat.message chat.edited], queue: 'realtime', retry: 3, reserve_for: 60
```

- Each topic in `topics` makes one subscription.
- The job type of the copy is the `event` of the class. The default is the class name.
- The copy has the `queue`, `retry`, and `reserve_for` of the class. Without a queue, the copy goes to `default`.
- `topics` from more than one `anway_options` call add up, with no duplicates. For a single value, such as `queue`, the last call wins, so all topics of a class use the same queue. To send the events of one topic to another queue, use another class with another event.
- A subclass does not get the `topics` or the `event` of its parent.
- Each worker start sends `SUBSCRIBE` for the subscriptions of all job classes. `SUBSCRIBE` is idempotent. A change of `retry` or `reserve_for` applies at the next start.

The README explains all keys of `anway_options` and the merge rules.

### With the client

```ruby
client.subscribe('chat.message', queue: 'realtime', event: 'BroadcastMessage', retry: 3, reserve_for: 60)
client.unsubscribe('chat.message', queue: 'realtime', event: 'BroadcastMessage')
```

Both return `true`. A missing subscription is not an error for `unsubscribe`.

The worker does not send `UNSUBSCRIBE`. The server keeps a subscription on disk, so copies go to the queue while the app is down. When you remove a topic from `topics`, remove the subscription with `client.unsubscribe`, or its copies wait in the queue.

## Queues of the worker

Without `queues` in `config/anway.yml` and without `-q`, the worker fetches the queues of its job classes, the queues of their subscriptions, and `default`.

With a queue list, the worker fetches only that list. For a subscription queue that is not in the list, the worker logs a warning at start:

```text
anway does not fetch queue realtime, so the events of topic chat.message wait there. Add the queue to queues.
```

Add the queue to the list.

## Plain Ruby

`Anway::Runner` sends the subscriptions of all registered job classes. To send other subscriptions, give a list of `Anway::Worker::Subscription`:

```ruby
runner = Anway::Runner.new(
  queues: %w[realtime],
  subscriptions: BroadcastMessage.subscriptions
)

runner.run
```

`Anway::Worker.subscriptions` returns the subscriptions of all registered classes.

## Delivery

- Each copy is delivered at least once. Handlers must be idempotent. Use `job.custom['event']` as the key.
- Copies in different queues have no order between them. A queue keeps its own order.
- There are no filters. Each subscriber gets every event of the topic, and skips the events that it does not need.
- An event that you publish before a subscription exists does not go to that subscription.

## An event with no subscription

The server does not lose an event with no subscription. It puts the event in the Dead set as one job, with the topic name as the job type. The reply has `jobs: 0`. When you requeue this job, the server publishes the event again to the subscriptions of that moment.

## Tests in your app

```ruby
require 'anway/testing'

Anway::Testing.fake!
Anway.publish('chat.message', [{ 'body' => 'hi' }], id: 'msg-42')

Anway::Testing.events
# => [{ "topic" => "chat.message", "args" => [{ "body" => "hi" }], "id" => "msg-42" }]

Anway::Testing.inline!
Anway.publish('chat.message', [{ 'body' => 'hi' }])  # runs each subscribed class of the app
```

- In fake mode, `Anway::Testing.events` keeps each event as the `PUBLISH` payload, with string keys. `Anway::Testing.clear` empties it.
- In inline mode, the gem also runs one copy in each job class of the app that subscribes to the topic. The copy has `custom` with `topic` and `event`.
- In both modes, `jobs` in the reply is the number of subscriptions in the job classes of the app. There is no duplicate check.

## Problems

| Problem | Cause and fix |
|---|---|
| `publish` returns `jobs: 0` | The topic has no subscription. Start the subscriber worker one time, so that it sends `SUBSCRIBE`. The event is in the Dead set. Requeue it after the subscription exists. |
| Copies wait in a queue and do not run | The worker does not fetch that queue. Look for the `does not fetch queue` warning, and add the queue to `queues`. |
| Copies still go to a queue after you removed a topic from `topics` | The server keeps the subscription. Call `client.unsubscribe`. |
| `Anway::ServerError` at worker start | The server is older than v0.3.0 and does not know `SUBSCRIBE`. Update the server. |
| A handler runs the same event two times | Delivery is at least once. Make the handler idempotent with `job.custom['event']`. |
