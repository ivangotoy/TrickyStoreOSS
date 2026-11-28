/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

package android.os;

/** Test-only stand-in for the hidden framework class (the :stub project is absent from unit tests). */
public class ServiceSpecificException extends RuntimeException {
    public final int errorCode;

    public ServiceSpecificException(int errorCode, String message) {
        super(message);
        this.errorCode = errorCode;
    }

    public ServiceSpecificException(int errorCode) {
        this.errorCode = errorCode;
    }
}
