import 'dart:convert';

import 'package:flutter/services.dart';

import 'place.dart';

abstract interface class PlaceDataStore {
  Future<PlaceData?> load();
  Future<void> save(PlaceData data);
}

final class PlacePersistenceException implements Exception {
  const PlacePersistenceException(this.message);
  final String message;
  @override
  String toString() => 'PlacePersistenceException: $message';
}

final class MethodChannelPlaceDataStore implements PlaceDataStore {
  MethodChannelPlaceDataStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'pingplace/places';
  final MethodChannel _channel;

  @override
  Future<PlaceData?> load() async {
    final raw = await _channel.invokeMethod<String>('loadState');
    if (raw == null) return null;
    try {
      return PlaceData.fromJson(
        Map<Object?, Object?>.from(jsonDecode(raw) as Map),
      );
    } on FormatException catch (error) {
      throw PlacePersistenceException(error.message);
    } catch (_) {
      throw const PlacePersistenceException('Stored place data is corrupt');
    }
  }

  @override
  Future<void> save(PlaceData data) async {
    data.validate();
    final committed = await _channel.invokeMethod<bool>(
      'saveState',
      jsonEncode(data.toJson()),
    );
    if (committed != true) {
      throw const PlacePersistenceException('Place data commit failed');
    }
  }
}

final class InMemoryPlaceDataStore implements PlaceDataStore {
  PlaceData? data;
  bool failWrites = false;
  int writes = 0;

  @override
  Future<PlaceData?> load() async => data;

  @override
  Future<void> save(PlaceData value) async {
    value.validate();
    if (failWrites) {
      throw const PlacePersistenceException('Place data commit failed');
    }
    data = value;
    writes++;
  }
}

final class PlaceDatabaseChange<T> {
  const PlaceDatabaseChange({
    required this.data,
    required this.result,
    this.persist = true,
  });
  final PlaceData data;
  final T result;
  final bool persist;
}

final class PlaceDatabase {
  PlaceDatabase(this.store);
  final PlaceDataStore store;
  Future<void> _tail = Future<void>.value();

  Future<PlaceData> _load() async => await store.load() ?? const PlaceData();

  Future<PlaceData> read() async {
    final data = await _load();
    data.validate();
    return data;
  }

  Future<T> transact<T>(
    Future<PlaceDatabaseChange<T>> Function(PlaceData current) change,
  ) {
    final next = _tail.then((_) async {
      final current = await _load();
      current.validate();
      final updated = await change(current);
      updated.data.validate();
      if (updated.persist) {
        await store.save(updated.data);
      }
      return updated.result;
    });
    _tail = next.then<void>((_) {}).catchError((Object _) {});
    return next;
  }

  Future<void> replace(PlaceData data) async {
    await transact<void>(
      (_) async => PlaceDatabaseChange<void>(data: data, result: null),
    );
  }

  Future<T> update<T>(PlaceData Function(PlaceData data) change) => transact<T>(
    (current) async =>
        PlaceDatabaseChange<T>(data: change(current), result: null as T),
  );
}

final class PlaceRepository {
  PlaceRepository(PlaceDatabase database) : _database = database;
  final PlaceDatabase _database;

  Future<List<Place>> list() async =>
      (await _database.read()).places.toList(growable: false);

  Future<Place?> get(String id) async {
    for (final place in await list()) {
      if (place.id == id) return place;
    }
    return null;
  }

  Future<void> create(Place place) async {
    place.validate();
    await _database.update<void>((data) {
      if (data.places.any((candidate) => candidate.id == place.id)) {
        throw StateError('Place already exists: ${place.id}');
      }
      return PlaceData(
        places: [...data.places, place],
        reminders: data.reminders,
      );
    });
  }

  Future<void> update(Place place) async {
    place.validate();
    await _database.update<void>((data) {
      if (!data.places.any((candidate) => candidate.id == place.id)) {
        throw StateError('Place does not exist: ${place.id}');
      }
      return PlaceData(
        places: [
          for (final candidate in data.places)
            candidate.id == place.id ? place : candidate,
        ],
        reminders: data.reminders,
      );
    });
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final place = await get(id);
    if (place == null) throw StateError('Place does not exist: $id');
    await update(place.copyWith(enabled: enabled));
  }

  Future<void> delete(String id) async {
    await _database.update<void>((data) {
      if (!data.places.any((candidate) => candidate.id == id)) {
        throw StateError('Place does not exist: $id');
      }
      return PlaceData(
        places: data.places.where((place) => place.id != id).toList(),
        reminders: data.reminders
            .where((reminder) => reminder.placeId != id)
            .toList(),
      );
    });
  }
}

final class ReminderRepository {
  ReminderRepository(PlaceDatabase database) : _database = database;
  final PlaceDatabase _database;

  Future<List<Reminder>> list({String? placeId}) async {
    final reminders = (await _database.read()).reminders;
    return reminders
        .where((reminder) => placeId == null || reminder.placeId == placeId)
        .toList(growable: false);
  }

  Future<Reminder?> get(String id) async {
    for (final reminder in await list()) {
      if (reminder.id == id) return reminder;
    }
    return null;
  }

  Future<void> create(Reminder reminder) async {
    reminder.validate();
    await _database.update<void>((data) {
      if (!data.places.any((place) => place.id == reminder.placeId)) {
        throw StateError('Place does not exist: ${reminder.placeId}');
      }
      if (data.reminders.any((candidate) => candidate.id == reminder.id)) {
        throw StateError('Reminder already exists: ${reminder.id}');
      }
      return PlaceData(
        places: data.places,
        reminders: [...data.reminders, reminder],
      );
    });
  }

  Future<void> update(Reminder reminder) async {
    reminder.validate();
    await _database.update<void>((data) {
      if (!data.reminders.any((candidate) => candidate.id == reminder.id)) {
        throw StateError('Reminder does not exist: ${reminder.id}');
      }
      if (!data.places.any((place) => place.id == reminder.placeId)) {
        throw StateError('Place does not exist: ${reminder.placeId}');
      }
      return PlaceData(
        places: data.places,
        reminders: [
          for (final candidate in data.reminders)
            candidate.id == reminder.id ? reminder : candidate,
        ],
      );
    });
  }

  Future<void> delete(String id) async {
    await _database.update<void>((data) {
      if (!data.reminders.any((candidate) => candidate.id == id)) {
        throw StateError('Reminder does not exist: $id');
      }
      return PlaceData(
        places: data.places,
        reminders: data.reminders
            .where((reminder) => reminder.id != id)
            .toList(),
      );
    });
  }
}
