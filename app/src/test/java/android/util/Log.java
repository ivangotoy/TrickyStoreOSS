/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package android.util;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Test-only replacement for the unit-test android.jar class (test classes come first on the test
 * classpath): records every line Logger prints so tests can check what was logged.
 */
public final class Log {
    public static final int VERBOSE = 2;
    public static final int DEBUG = 3;
    public static final int INFO = 4;
    public static final int WARN = 5;
    public static final int ERROR = 6;

    public static final List<String> lines = new CopyOnWriteArrayList<>();

    public static int println(int priority, String tag, String msg) {
        lines.add(priority + " " + msg);
        return 0;
    }

    public static String getStackTraceString(Throwable tr) {
        return String.valueOf(tr);
    }
}
