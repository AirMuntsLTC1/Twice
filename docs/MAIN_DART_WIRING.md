# Minimal main.dart wiring changes

## A. Imports (add near top)

```dart
import 'messages_page.dart';
import 'widgets/skeleton.dart';
import 'widgets/ig_icons.dart';
import 'data/inbox_controller.dart';
```

## B. After sign-in (TwiceShell.initState)

```dart
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addObserver(this);
  InboxController.instance.start();
  _loadAll();
}
```

And in dispose / sign-out:

```dart
InboxController.instance.stop();
```

## C. Feed loading → skeleton

Where you currently show a spinner while `loading` is true:

```dart
if (loading) {
  return const FeedSkeleton();   // instead of CircularProgressIndicator
}
```

## D. Messages entry point

Any `Navigator.push(... MessagesPage())` continues to work — the new file uses the same class name.

Optional: show badge on the messenger icon in the app bar:

```dart
ListenableBuilder(
  listenable: InboxController.instance,
  builder: (_, __) {
    final n = InboxController.instance.messageUnread;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const IgMessenger(size: 26),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MessagesPage()),
          ),
        ),
        if (n > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Color(0xFFFF3040),
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                n > 9 ? '9+' : '$n',
                style: const TextStyle(color: Colors.white, fontSize: 10),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  },
)
```

## E. Post action icons (feed)

Replace the old Row of Icons with:

```dart
IgActionRow(
  liked: post.liked,
  saved: post.saved,
  likeCount: post.likes,
  onLike: () { /* existing toggle like */ },
  onComment: () { /* open comments sheet */ },
  onShare: () { /* share_plus */ },
  onSave: () { /* existing toggle save */ },
)
```

## F. Videos side rail

```dart
IgActionRow(
  vertical: true,
  liked: liked,
  saved: saved,
  likeCount: likes,
  onLike: onLike,
  onComment: onComment,
  onShare: onShare,
  onSave: onSave,
)
```

## G. Boot timing (already partially in your main)

Keep the deferred Supabase boot pattern you already have:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // theme / system UI
  TwiceMedia.configure();
  runApp(const TwiceApp());          // first frame immediately
  unawaited(_bootSupabase());        // network after first paint
  unawaited(TwiceMedia.trimDiskCache());
}
```

Show `FeedSkeleton` until both `supabaseBootFinished` **and** the first `cachedFeed()` / network feed resolve. That is the Instagram / Facebook feel: never a blank white/black screen, always structure first.
