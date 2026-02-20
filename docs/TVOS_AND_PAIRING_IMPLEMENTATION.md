# tvOS Target + Pairing Flow Implementation

## What Was Added

### 1. tvOS App Target

- **New target**: `DS Video clone tvOS` in the Xcode project
- **Bundle ID**: `HeiloProjects.DSVideoClone.tvOS`
- **Deployment target**: tvOS 17.0
- **Shared scheme**: `DS Video clone tvOS.xcscheme` (in `xcshareddata/xcschemes/`)
- **Asset catalog**: Separate `AssetsTV.xcassets` with tvOS app icons (400x240, 1280x768) and top shelf images (1920x720, 2320x720)

### 2. tvOS Home Screen with Rails

**File**: `DSVideo/Views/TVMainView.swift`

- **Vertical scrolling** home screen with horizontal **rails**
- **Rails include**:
  - "Continue Watching" (items with progress)
  - "Just Added" (recent items)
  - One rail per library (Movies, TV Shows, Home Videos)
- **Poster cards**: 300x450px with focus states, progress indicators, title/year
- **Navigation**: Tap poster → `ItemDetailView`, tap library title → `ItemsGridView`

**Key tvOS patterns**:
- `.focusable()` on poster cards
- Horizontal `ScrollView` + `LazyHStack` for rails
- Large, readable typography
- Dark background with white text

### 3. Pairing Code Flow

#### Backend (`backend/server.py`)

**New database table**: `pairing_codes`
- Stores 6-digit codes with expiration (10 minutes)
- Single-use (deleted after exchange)
- Auto-cleanup of expired codes

**New endpoints**:
- `POST /api/v1/auth/pairing/generate` - Generate code (requires auth)
- `POST /api/v1/auth/pairing/exchange` - Exchange code for token (public)

**New App methods**:
- `generate_pairing_code(user_id, username)` → returns 6-digit code
- `exchange_pairing_code(code)` → returns user info or None

#### iOS Client

**New view**: `DSVideo/Views/PairingCodeView.swift`
- Manual 6-digit code entry field
- QR code scanner (using `AVFoundation`)
- Camera permission in Info.plist (`NSCameraUsageDescription`)
- Integrates with `AppState.exchangePairingCode()`

**Updated**: `LoginView.swift`
- Added "Pair with Apple TV" button
- Opens `PairingCodeView` as sheet

**New API methods** (`APIClient.swift`):
- `generatePairingCode()` → `PairingCodeResponse`
- `exchangePairingCode(code:)` → `LoginResponse`

**New models** (`APIModels.swift`):
- `PairingCodeResponse`
- `PairingCodeExchangeRequest`

**AppState updates**:
- `pairingCode`, `isGeneratingPairingCode`, `pairingError` properties
- `generatePairingCode()` method
- `exchangePairingCode(_:)` method

#### tvOS Client

**New view**: `DSVideo/Views/TVPairingView.swift`
- Large, monospaced 6-digit code display
- Countdown timer (10 minutes)
- "Generate New Code" button
- Auto-generates code on appear
- Red brand background matching DS Video style

**Updated**: `TVMainView.swift`
- Routes to `TVPairingView` when `sessionToken == nil`
- Routes to `TVHomeView` (rails) when logged in

## User Flow

### tvOS
1. Launch app → see pairing code screen
2. Code auto-generates (e.g., "123456")
3. Code expires in 10 minutes
4. User can generate new code anytime
5. After pairing succeeds → home screen with rails

### iOS
1. On login screen → tap "Pair with Apple TV"
2. See pairing entry screen
3. Option A: Enter 6-digit code manually
4. Option B: Tap "Scan QR Code" → camera opens → scan code
5. Code validated → user logged in → returns to main app

## Technical Notes

- **Pairing codes are 6 digits** (numeric only) for easy remote entry
- **Codes expire after 10 minutes** (configurable in backend)
- **Single-use**: code deleted immediately after successful exchange
- **Backend cleanup**: expired codes removed periodically (roughly once per minute)
- **QR scanning**: iOS uses `AVCaptureMetadataOutput` with `.qr` type
- **Focus management**: tvOS posters use `.focusable()` for remote navigation

## Future Enhancements

1. **QR code generation on backend**: Return QR image data URL containing pairing code
2. **QR display on tvOS**: Show QR code alongside numeric code for iOS scanning
3. **Handoff/Continuity**: Use Apple's Handoff framework for automatic pairing
4. **Code format**: Consider 8-digit codes or alphanumeric for better security
5. **Multi-device pairing**: Allow one code to pair multiple devices

## Build Status

- ✅ **iOS build**: Succeeds
- ✅ **Backend syntax**: Valid
- ⚠️ **tvOS build**: Requires tvOS 26.2 platform installation in Xcode

To build tvOS:
1. Open Xcode → Settings → Components
2. Install "tvOS 26.2" platform
3. Build scheme: `DS Video clone tvOS`
