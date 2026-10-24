package com.example.pingplace

import android.content.Context

internal class AndroidDesiredRegistrationStorage(context: Context) :
    DesiredRegistrationStore.Storage {
    private val app = context.applicationContext
    private val preferences =
        app.getSharedPreferences(GeofenceRecovery.REGISTRATION_PREFS, Context.MODE_PRIVATE)

    override fun current(): Map<String, *> = preferences.all

    override fun legacy(): List<Map<String, *>> =
        listOf("MainActivity_preferences", "com.example.pingplace.MainActivity_preferences").map {
            app.getSharedPreferences(it, Context.MODE_PRIVATE).all
        }

    override fun runtime(): Map<String, *> =
        app.getSharedPreferences("pingplace_runtime", Context.MODE_PRIVATE).all

    override fun commitRecord(serialized: String): Boolean =
        preferences.edit().putString(DesiredRegistrationStore.KEY, serialized).commit()
}
