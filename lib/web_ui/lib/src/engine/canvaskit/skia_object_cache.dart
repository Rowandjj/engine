// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.12
part of engine;

/// A cache of Skia objects whose memory Flutter manages.
///
/// When using Skia, Flutter creates Skia objects which are allocated in
/// WASM memory and which must be explicitly deleted. In the case of Flutter
/// mobile, the Skia objects are wrapped by a C++ class which is destroyed
/// when the associated Dart object is garbage collected.
///
/// On the web, we cannot tell when a Dart object is garbage collected, so
/// we must use other strategies to know when to delete a Skia object. Some
/// objects, like [ui.Paint], can safely delete their associated Skia object
/// because they can always recreate the Skia object from data stored in the
/// Dart object. Other objects, like [ui.Picture], can be serialized to a
/// JS-managed data structure when they are deleted so that when the associated
/// object is garbage collected, so is the serialized data.
class SkiaObjectCache {
  final int maximumSize;

  /// A doubly linked list of the objects in the cache.
  ///
  /// This makes it fast to move a recently used object to the front.
  final DoubleLinkedQueue<SkiaObject> _itemQueue;

  /// A map of objects to their associated node in the [_itemQueue].
  ///
  /// This makes it fast to find the node in the queue when we need to
  /// move the object to the front of the queue.
  final Map<SkiaObject, DoubleLinkedQueueEntry<SkiaObject>> _itemMap;

  SkiaObjectCache(this.maximumSize)
      : _itemQueue = DoubleLinkedQueue<SkiaObject>(),
        _itemMap = <SkiaObject, DoubleLinkedQueueEntry<SkiaObject>>{};

  /// The number of objects in the cache.
  int get length => _itemQueue.length;

  /// Whether or not [object] is in the cache.
  ///
  /// This is only for testing.
  @visibleForTesting
  bool debugContains(SkiaObject object) {
    return _itemMap.containsKey(object);
  }

  /// Adds [object] to the cache.
  ///
  /// If adding [object] causes the total size of the cache to exceed
  /// [maximumSize], then the least recently used half of the cache
  /// will be deleted.
  void add(SkiaObject object) {
    _itemQueue.addFirst(object);
    _itemMap[object] = _itemQueue.firstEntry()!;

    if (_itemQueue.length > maximumSize) {
      SkiaObjects.markCacheForResize(this);
    }
  }

  /// Records that [object] was used in the most recent frame.
  void markUsed(SkiaObject object) {
    DoubleLinkedQueueEntry<SkiaObject> item = _itemMap[object]!;
    item.remove();
    _itemQueue.addFirst(object);
    _itemMap[object] = _itemQueue.firstEntry()!;
  }

  /// Deletes the least recently used half of this cache.
  void resize() {
    final int itemsToDelete = maximumSize ~/ 2;
    for (int i = 0; i < itemsToDelete; i++) {
      final SkiaObject oldObject = _itemQueue.removeLast();
      _itemMap.remove(oldObject);
      oldObject.delete();
      oldObject.didDelete();
    }
  }
}

/// An object backed by a JavaScript object mapped onto a Skia C++ object in the
/// WebAssembly heap.
///
/// These objects are automatically deleted when no longer used.
abstract class SkiaObject<T extends Object> {
  /// The JavaScript object that's mapped onto a Skia C++ object in the WebAssembly heap.
  T get skiaObject;

  /// Deletes the associated C++ object from the WebAssembly heap.
  void delete();

  /// Lifecycle method called immediately after calling [delete].
  ///
  /// This method is used to
  void didDelete();
}

/// A [SkiaObject] that manages the lifecycle of its C++ counterpart.
///
/// In browsers that support weak references we use feedback from the garbage
/// collector to determine when it is safe to release the C++ object.
///
/// In browsers that do not support weak references we pessimistically delete
/// the underlying C++ object before the Dart object is garbage-collected.
///
/// If [isResurrectionExpensive] is false the object is deleted at the end of
/// the frame. If a deleted object is reused in a subsequent frame it is
/// resurrected by calling [resurrect]. This allows reusing the C++ objects
/// within the frame.
///
/// If [isResurrectionExpensive] is true the object is put in a LRU cache.
/// Objects that are used least frequently are deleted from the cache when
/// the cache limit is reached.
///
/// The lifecycle of a resurrectable C++ object is as follows:
///
/// - Create: a managed object is created using a default instance that's
///   either supplied as a constructor argument, or obtained by calling
///   [createDefault]. The data in the new object is expected to contain
///   data matching Flutter's defaults (sometimes Skia defaults need to be
///   adjusted).
/// - Zero or more cycles of delete + resurrect: when a Dart object is reused
///   after its C++ object is deleted we create a new C++ object populated with
///   data from the current state of the Dart object. This is done using the
///   [resurrect] method.
/// - Final delete: if a Dart object is never reused, it is GC'd after its
///   underlying C++ object is deleted. This is implemented by [SkiaObjects].
abstract class ManagedSkiaObject<T extends Object> extends SkiaObject<T> {
  /// Creates a managed Skia object.
  ///
  /// If `instance` is null calls [createDefault] to create a Skia object to
  /// manage. Otherwise, uses the provided instance.
  ///
  /// The provided instance must not be managed by another [ManagedSkiaObject],
  /// as it may lead to undefined behavior.
  ManagedSkiaObject([T? instance]) {
    final T defaultObject = instance ?? createDefault();
    rawSkiaObject = defaultObject;
    if (browserSupportsFinalizationRegistry) {
      // If FinalizationRegistry is supported we will only ever need the
      // default object, as we know precisely when to delete it.
      Collector.instance.register(this, defaultObject as SkDeletable);
    } else {
      // If FinalizationRegistry is _not_ supported we may need to delete
      // and resurrect the object multiple times before deleting it forever.
      if (isResurrectionExpensive) {
        SkiaObjects.manageExpensive(this);
      } else {
        SkiaObjects.manageResurrectable(this);
      }
    }
  }

  @override
  T get skiaObject => rawSkiaObject ?? _doResurrect();

  T _doResurrect() {
    assert(!browserSupportsFinalizationRegistry);
    final T skiaObject = resurrect();
    rawSkiaObject = skiaObject;
    if (isResurrectionExpensive) {
      SkiaObjects.manageExpensive(this);
    } else {
      SkiaObjects.manageResurrectable(this);
    }
    return skiaObject;
  }

  @override
  void didDelete() {
    assert(!browserSupportsFinalizationRegistry);
    rawSkiaObject = null;
  }

  /// Returns the current skia object as is without attempting to
  /// resurrect it.
  ///
  /// If the returned value is `null`, the corresponding C++ object has
  /// been deleted.
  ///
  /// Use this field instead of the [skiaObject] getter when implementing
  /// the [delete] method.
  T? rawSkiaObject;

  /// Instantiates a new Skia-backed JavaScript object containing default
  /// values.
  ///
  /// The object is expected to represent Flutter's defaults. If Skia uses
  /// different defaults from those used by Flutter, this method is expected
  /// initialize the object to Flutter's defaults.
  T createDefault();

  /// Creates a new Skia-backed JavaScript object containing data representing
  /// the current state of the Dart object.
  T resurrect();

  /// Whether or not it is expensive to resurrect this object.
  ///
  /// Defaults to false.
  bool get isResurrectionExpensive => false;
}

// TODO(hterkelsen): [OneShotSkiaObject] is dangerous because it might delete
//     the underlying Skia object while the associated Dart object is still in
//     use. This issue discusses ways to address this:
//     https://github.com/flutter/flutter/issues/60401
/// A [SkiaObject] which is deleted once and cannot be used again.
///
/// In browsers that support weak references we use feedback from the garbage
/// collector to determine when it is safe to release the C++ object. Otherwise,
/// we use an LRU cache (see [SkiaObjects.manageOneShot]).
abstract class OneShotSkiaObject<T extends Object> extends SkiaObject<T> {
  /// Returns the current skia object as is without attempting to
  /// resurrect it.
  ///
  /// If the returned value is `null`, the corresponding C++ object has
  /// been deleted.
  ///
  /// Use this field instead of the [skiaObject] getter when implementing
  /// the [delete] method.
  T rawSkiaObject;

  bool _isDeleted = false;

  OneShotSkiaObject(T skObject) : this.rawSkiaObject = skObject {
    if (browserSupportsFinalizationRegistry) {
      Collector.instance.register(this, skObject as SkDeletable);
    } else {
      SkiaObjects.manageOneShot(this);
    }
  }

  @override
  T get skiaObject {
    if (browserSupportsFinalizationRegistry) {
      return rawSkiaObject;
    }
    if (_isDeleted) {
      throw StateError('Attempting to use a Skia object that has been freed.');
    }
    SkiaObjects.oneShotCache.markUsed(this);
    return rawSkiaObject;
  }

  @override
  void didDelete() {
    _isDeleted = true;
  }
}

/// Interface that classes wrapping [SkiaObjectBox] must implement.
///
/// Used to collect stack traces in debug mode.
abstract class StackTraceDebugger {
  /// The stack trace pointing to code location that created or upreffed a
  /// [SkiaObjectBox].
  StackTrace get debugStackTrace;
}

/// A function that restores a Skia object that was temporarily deleted.
typedef Resurrector<T> = T Function();

/// Uses reference counting to manage the lifecycle of a Skia object owned by a
/// wrapper object.
///
/// The [ref] method can be used to increment the refcount to tell this box to
/// keep the underlying Skia object alive.
///
/// The [unref] method can be used to decrement the refcount to tell this box
/// that a wrapper object no longer needs it. When the refcount drops to zero
/// the underlying Skia object is deleted permanently (see [isDeletedPermanently]).
///
/// In addition to ref counting, this object is also managed by GC. In browsers
/// that support [SkFinalizationRegistry] the underlying Skia object is deleted
/// permanently when no JavaScript objects have references to this box. In
/// browsers that do not support [SkFinalizationRegistry] the underlying Skia
/// object may undergo several cycles of temporary deletions and resurrections
/// prior to being deleted permanently. A temporary deletion may effectively
/// be permanent if this object is garbage collected. This is safe because a
/// temporarily deleted object has no C++ resources to collect.
class SkiaObjectBox<R extends StackTraceDebugger, T extends Object> extends SkiaObject<T> {
  /// Creates an object box that's memory-managed using [SkFinalizationRegistry].
  ///
  /// This constructor must only be used if [browserSupportsFinalizationRegistry] is true.
  SkiaObjectBox(R debugReferrer, T initialValue) : _resurrector = null {
    assert(browserSupportsFinalizationRegistry);
    _initialize(debugReferrer, initialValue);
    Collector.instance.register(this, _skDeletable!);
  }

  /// Creates an object box that's memory-managed using a [Resurrector].
  ///
  /// This constructor must only be used if [browserSupportsFinalizationRegistry] is false.
  SkiaObjectBox.resurrectable(R debugReferrer, T initialValue, this._resurrector) {
    assert(!browserSupportsFinalizationRegistry);
    _initialize(debugReferrer, initialValue);
    SkiaObjects.manageExpensive(this);
  }

  void _initialize(R debugReferrer, T initialValue) {
    _update(initialValue);
    if (assertionsEnabled) {
      debugReferrers.add(debugReferrer);
    }
    assert(refCount == debugReferrers.length);
  }

  /// The number of objects sharing references to this box.
  ///
  /// When this count reaches zero, the underlying [skiaObject] is scheduled
  /// for deletion.
  int get refCount => _refCount;
  int _refCount = 1;

  /// When assertions are enabled, stores all objects that share this box.
  ///
  /// The length of this list is always identical to [refCount].
  ///
  /// This list can be used for debugging ref counting issues.
  final Set<R> debugReferrers = <R>{};

  /// If asserts are enabled, the [StackTrace]s representing when a reference
  /// was created.
  List<StackTrace>? debugGetStackTraces() {
    if (assertionsEnabled) {
      return debugReferrers
          .map<StackTrace>((R referrer) => referrer.debugStackTrace)
          .toList();
    }
    return null;
  }

  /// The Skia object whose lifecycle is being managed.
  ///
  /// Do not store this value outside this box. It is memory-managed by
  /// [SkiaObjectBox]. Storing it may result in use-after-free bugs.
  T? rawSkiaObject;
  SkDeletable? _skDeletable;
  Resurrector<T>? _resurrector;

  void _update(T? newSkiaObject) {
    rawSkiaObject = newSkiaObject;
    _skDeletable = newSkiaObject as SkDeletable?;
  }

  @override
  T get skiaObject => rawSkiaObject ?? _doResurrect();

  T _doResurrect() {
    assert(!browserSupportsFinalizationRegistry);
    assert(_resurrector != null);
    assert(!_isDeletedPermanently, 'Cannot use deleted object.');
    _update(_resurrector!());
    SkiaObjects.manageExpensive(this);
    return skiaObject;
  }

  @override
  void delete() {
    _skDeletable?.delete();
  }

  @override
  void didDelete() {
    assert(!browserSupportsFinalizationRegistry);
    _update(null);
  }

  /// Whether this object has been deleted permanently.
  ///
  /// If this is true it will remain true forever, and the Skia object is no
  /// longer resurrectable.
  ///
  /// See also [isDeletedTemporarily].
  bool get isDeletedPermanently => _isDeletedPermanently;
  bool _isDeletedPermanently = false;

  /// Whether the underlying [rawSkiaObject] has been deleted, but it may still
  /// be resurrected (see [SkiaObjectBox.resurrectable]).
  bool get isDeletedTemporarily => rawSkiaObject == null && !_isDeletedPermanently;

  /// Increases the reference count of this box because a new object began
  /// sharing ownership of the underlying [skiaObject].
  ///
  /// Clones must be [dispose]d when finished.
  void ref(R debugReferrer) {
    assert(!_isDeletedPermanently, 'Cannot increment ref count on a deleted handle.');
    assert(_refCount > 0);
    assert(
      debugReferrers.add(debugReferrer),
      'Attempted to increment ref count by the same referrer more than once.',
    );
    _refCount += 1;
    assert(refCount == debugReferrers.length);
  }

  /// Decrements the reference count for the [skObject].
  ///
  /// Does nothing if the object has already been deleted.
  ///
  /// If this causes the reference count to drop to zero, deletes the
  /// [skObject].
  void unref(R debugReferrer) {
    assert(!_isDeletedPermanently, 'Attempted to unref an already deleted Skia object.');
    assert(
      debugReferrers.remove(debugReferrer),
      'Attempted to decrement ref count by the same referrer more than once.',
    );
    _refCount -= 1;
    assert(refCount == debugReferrers.length);
    if (_refCount == 0) {
      // The object may be null because it was deleted temporarily, i.e. it was
      // expecting the possibility of resurrection.
      if (_skDeletable != null) {
        if (browserSupportsFinalizationRegistry) {
          Collector.instance.collect(_skDeletable!);
        } else {
          _skDeletable!.delete();
        }
      }
      rawSkiaObject = null;
      _skDeletable = null;
      _resurrector = null;
      _isDeletedPermanently = true;
    }
  }
}

/// Singleton that manages the lifecycles of [SkiaObject] instances.
class SkiaObjects {
  @visibleForTesting
  static final List<ManagedSkiaObject> resurrectableObjects =
      <ManagedSkiaObject>[];

  @visibleForTesting
  static int maximumCacheSize = 8192;

  @visibleForTesting
  static final SkiaObjectCache oneShotCache = SkiaObjectCache(maximumCacheSize);

  @visibleForTesting
  static final SkiaObjectCache expensiveCache =
      SkiaObjectCache(maximumCacheSize);

  @visibleForTesting
  static final List<SkiaObjectCache> cachesToResize = <SkiaObjectCache>[];

  static bool _addedCleanupCallback = false;

  @visibleForTesting
  static void registerCleanupCallback() {
    if (_addedCleanupCallback) {
      return;
    }
    EnginePlatformDispatcher.instance.rasterizer!.addPostFrameCallback(postFrameCleanUp);
    _addedCleanupCallback = true;
  }

  /// Starts managing the lifecycle of resurrectable [object].
  ///
  /// These can safely be deleted at any time.
  static void manageResurrectable(ManagedSkiaObject object) {
    registerCleanupCallback();
    resurrectableObjects.add(object);
  }

  /// Starts managing the lifecycle of a one-shot [object].
  ///
  /// We should avoid deleting these whenever we can, since we won't
  /// be able to resurrect them.
  static void manageOneShot(OneShotSkiaObject object) {
    registerCleanupCallback();
    oneShotCache.add(object);
  }

  /// Starts managing the lifecycle of a resurrectable object that is expensive.
  ///
  /// Since it's expensive to resurrect, we shouldn't just delete it after every
  /// frame. Instead, add it to a cache and only delete it when the cache fills.
  static void manageExpensive(SkiaObject object) {
    registerCleanupCallback();
    expensiveCache.add(object);
  }

  /// Marks that [cache] has overflown its maximum size and show be resized.
  static void markCacheForResize(SkiaObjectCache cache) {
    registerCleanupCallback();
    if (cachesToResize.contains(cache)) {
      return;
    }
    cachesToResize.add(cache);
  }

  /// Cleans up managed Skia memory.
  static void postFrameCleanUp() {
    if (resurrectableObjects.isEmpty && cachesToResize.isEmpty) {
      return;
    }

    for (int i = 0; i < resurrectableObjects.length; i++) {
      final SkiaObject object = resurrectableObjects[i];
      object.delete();
      object.didDelete();
    }
    resurrectableObjects.clear();

    for (int i = 0; i < cachesToResize.length; i++) {
      final SkiaObjectCache cache = cachesToResize[i];
      cache.resize();
    }
    cachesToResize.clear();
  }
}
