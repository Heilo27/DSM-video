# Video Station Alternatives for DSM 7.3+

## Current Situation

- **DSM 7.2.1**: Video Station still works
- **DSM 7.3+**: Video Station is no longer supported/available
- **Your Goal**: Recreate Video Station functionality or find alternatives

## Video Station Source Code

**Video Station is proprietary** - Synology does not release the source code. It's a closed-source application that only Synology can update.

## Alternatives to Video Station

### 1. **Jellyfin** (Recommended - Open Source)
- **Status**: Fully open source, actively maintained
- **DSM Support**: Can run via Docker on Synology
- **Features**: 
  - Media library management
  - Streaming to multiple devices
  - Transcoding support
  - Web interface + mobile apps
  - Similar to Video Station in functionality
- **Installation**: 
  - Install Docker from Package Center
  - Run Jellyfin container
  - Access via web interface

### 2. **Plex Media Server**
- **Status**: Commercial (free tier available)
- **DSM Support**: Official Synology package available
- **Features**: 
  - Similar to Video Station
  - Better transcoding
  - More polished UI
  - Mobile apps available
- **Installation**: Available in Package Center (may require Plex Pass for some features)

### 3. **Emby**
- **Status**: Open source core, premium features available
- **DSM Support**: Can run via Docker
- **Features**: Similar to Jellyfin/Plex

### 4. **Your DS Video Clone** (Current Project)
- **Status**: In development
- **Goal**: Recreate Video Station functionality
- **Advantage**: Custom-built for your needs
- **Current State**: Backend built, needs iOS app integration

## Recommendation

### Short Term (Stay on DSM 7.2.1)
1. Continue using Video Station on DSM 7.2.1
2. Continue developing DS Video clone
3. Test DS Video clone alongside Video Station

### Long Term (Upgrade to DSM 7.3+)
1. **Option A**: Use Jellyfin (open source, similar features)
   - Install Docker
   - Run Jellyfin container
   - Migrate media library

2. **Option B**: Complete DS Video clone
   - Finish iOS app
   - Deploy backend to NAS
   - Replace Video Station with your solution

3. **Option C**: Use Plex
   - Install from Package Center
   - Migrate library
   - Use Plex apps

## Building Your Own Solution

Since Video Station source is not available, you're building a replacement. Your current project structure:

```
DS Video/
├── backend/          # Go backend (in progress)
├── DS Video clone/   # iOS app (in progress)
└── spk/             # Synology package (in progress)
```

**Next Steps:**
1. ✅ Backend is built and ready
2. ⏳ Package installation (current blocker)
3. ⏳ iOS app development
4. ⏳ Integration testing

## Resources

- **Jellyfin**: https://jellyfin.org/
- **Plex**: https://www.plex.tv/
- **Synology Docker Guide**: https://kb.synology.com/en-global/DSM/help/Docker/docker_desc
- **DSM 7.3 Release Notes**: Check Synology's website for Video Station deprecation details
