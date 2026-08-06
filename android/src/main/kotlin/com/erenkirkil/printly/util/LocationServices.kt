package com.erenkirkil.printly.util

import android.content.Context
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat

/**
 * Whether the OS location service gates Bluetooth scanning on this device.
 *
 * Below API 31 both Classic inquiry and BLE scanning return **no results at
 * all** when the service is off — the runtime permission is not enough and the
 * platform reports no error, so a scan looks like an empty room. From API 31
 * printly declares BLUETOOTH_SCAN with `neverForLocation`, which removes the
 * dependency entirely.
 */
internal object LocationServices {
    fun isRequired(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.S

    fun isEnabled(context: Context): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ContextCompat.getSystemService(context, LocationManager::class.java)
                ?.isLocationEnabled ?: true
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(
                context.contentResolver,
                Settings.Secure.LOCATION_MODE,
                Settings.Secure.LOCATION_MODE_OFF,
            ) != Settings.Secure.LOCATION_MODE_OFF
        }
    } catch (_: Throwable) {
        // Unreadable state: assume enabled rather than blocking a scan that
        // might have worked. A false negative here costs a silent empty scan;
        // a false positive would block scanning outright.
        true
    }

    /** The value reported to Dart: `true` when nothing is blocking scanning. */
    fun isSatisfied(context: Context): Boolean = !isRequired() || isEnabled(context)
}
