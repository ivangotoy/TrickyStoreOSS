/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package android.os;

/**
 * Test-only stand-in for the hidden framework class (the :stub project is compileOnly, so it is
 * absent from unit tests). Reports logd as running so Logger output reaches the android.util.Log
 * stand-in; every other property is unset.
 */
public class SystemProperties {
    public static String get(String key, String def) {
        return "init.svc.logd".equals(key) ? "running" : def;
    }

    public static String get(String key) {
        return get(key, "");
    }

    public static void set(String key, String value) {}
}
