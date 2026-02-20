# Pairing Flow (QR Code / Manual Entry)

## Overview

The DS Video clone supports a **pairing code flow** for tvOS authentication, allowing users to authenticate Apple TV without typing passwords on the remote.

## Flow

1. **tvOS app** (not logged in) → shows `TVPairingView`
2. User taps "Generate Pairing Code" → backend creates a **6-digit code** (valid for 10 minutes)
3. **iOS app** → user taps "Pair with Apple TV" on login screen
4. iOS app shows `PairingCodeView` with:
   - Manual entry field (6 digits)
   - QR code scanner button
5. User enters code (or scans QR if we add QR generation later) → iOS sends code to backend
6. Backend validates code → returns session token
7. iOS app stores token → user is logged in

## Backend Endpoints

### `POST /api/v1/auth/pairing/generate`
**Auth required**: Yes (Bearer token)

Generates a 6-digit pairing code for the authenticated user.

**Response**:
```json
{
  "code": "123456",
  "expiresInSeconds": 600
}
```

### `POST /api/v1/auth/pairing/exchange`
**Auth required**: No

Exchanges a pairing code for a session token.

**Request**:
```json
{
  "code": "123456"
}
```

**Response**:
```json
{
  "token": "<jwt>",
  "user": {
    "id": "u_admin",
    "username": "admin",
    "displayName": "admin"
  }
}
```

**Errors**:
- `invalid_pairing_code` - code format invalid
- `invalid_or_expired_pairing_code` - code not found or expired

## Implementation Details

- Pairing codes are stored in SQLite with expiration timestamps
- Codes are **single-use** (deleted after exchange)
- Expired codes are cleaned up periodically
- Codes are 6 digits (numeric only) for easy remote entry

## Future Enhancements

- Generate QR code image on backend containing the pairing code
- Display QR code on tvOS for iOS to scan
- Add pairing code to QR payload format: `dsvideo://pair?code=123456&server=...`
