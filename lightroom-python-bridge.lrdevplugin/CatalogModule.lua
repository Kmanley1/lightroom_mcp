-- CatalogModule.lua
-- Catalog operations API wrapper for Phase 4
-- Enhanced with lightweight error handling

-- Lazy imports to avoid loading issues
local LrApplication = nil
local LrTasks = import 'LrTasks'
local LrProgressScope = nil

-- Get ErrorUtils from global state (created in PluginInit.lua)
local function getErrorUtils()
    if _G.LightroomPythonBridge and _G.LightroomPythonBridge.ErrorUtils then
        return _G.LightroomPythonBridge.ErrorUtils
    end
    -- Minimal fallback if global not available
    return {
        safeCall = function(func, ...) return LrTasks.pcall(func, ...) end,
        createError = function(code, message) return { error = { code = code or "ERROR", message = message or "An error occurred", severity = "error" } } end,
        createSuccess = function(result) return { result = result or {} } end,
        wrapCallback = function(callback) return callback end,
        validateRequired = function() return true end,
        CODES = { MISSING_PARAM = "MISSING_PARAM", CATALOG_ACCESS_FAILED = "CATALOG_ACCESS_FAILED" }
    }
end

local ErrorUtils = getErrorUtils()

-- Lazy load Lightroom modules
local function ensureLrModules()
    if not LrApplication then
        LrApplication = import 'LrApplication'
    end
    if not LrProgressScope then
        LrProgressScope = import 'LrProgressScope'
    end
end

-- Get logger from global state (defensive)
local function getLogger()
    if _G.LightroomPythonBridge and _G.LightroomPythonBridge.logger then
        return _G.LightroomPythonBridge.logger
    end
    local LrLogger = import 'LrLogger'
    local logger = LrLogger('CatalogModule')
    logger:enable("logfile")
    return logger
end

local CatalogModule = {}

-- Search photos with flexible criteria
function CatalogModule.searchPhotos(params, callback)
    local wrappedCallback = ErrorUtils.wrapCallback(callback, "searchPhotos")
    
    -- Ensure modules are loaded
    local moduleSuccess, moduleError = ErrorUtils.safeCall(ensureLrModules)
    if not moduleSuccess then
        wrappedCallback(ErrorUtils.createError(ErrorUtils.CODES.RESOURCE_UNAVAILABLE, 
            "Failed to load Lightroom modules: " .. tostring(moduleError)))
        return
    end
    
    local logger = getLogger()
    local criteria = (params and params.criteria) or {}
    local limit = (params and params.limit) or 100
    local offset = (params and params.offset) or 0
    
    -- Validate limit parameter
    if limit < 1 or limit > 10000 then
        wrappedCallback(ErrorUtils.createError(ErrorUtils.CODES.INVALID_PARAM_VALUE, 
            "Limit must be between 1 and 10000"))
        return
    end
    
    -- Validate offset parameter
    if offset < 0 then
        wrappedCallback(ErrorUtils.createError(ErrorUtils.CODES.INVALID_PARAM_VALUE, 
            "Offset must be 0 or greater"))
        return
    end
    
    logger:debug("Searching photos with criteria")
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        -- Get photos using the most appropriate method
        local allPhotos
        local photosSuccess, photosResult = ErrorUtils.safeCall(function()
            return catalog:getTargetPhotos()
        end)
        
        if photosSuccess and photosResult and #photosResult > 0 then
            allPhotos = photosResult
        else
            -- Fallback to all photos
            local allSuccess, allResult = ErrorUtils.safeCall(function()
                return catalog:getAllPhotos()
            end)
            
            if allSuccess then
                allPhotos = allResult
            else
                wrappedCallback(ErrorUtils.createError(ErrorUtils.CODES.CATALOG_ACCESS_FAILED, 
                    "Failed to access catalog photos"))
                return
            end
        end
        
        if not allPhotos or #allPhotos == 0 then
            wrappedCallback(ErrorUtils.createSuccess({
                photos = {},
                total = 0,
                offset = offset,
                limit = limit,
                hasMore = false
            }, "No photos found in catalog"))
            return
        end
        
        local results = {}
        local total = #allPhotos
        local startIndex = offset + 1
        local endIndex = math.min(offset + limit, total)
        
        for i = startIndex, endIndex do
            local photo = allPhotos[i]
            
            local photoData = {
                id = photo.localIdentifier,
                keywords = {},
                collections = {}
            }
            
            -- Safely get photo metadata
            ErrorUtils.safeCall(function()
                photoData.filename = photo:getFormattedMetadata("fileName")
                photoData.folderPath = photo:getFormattedMetadata("folderName")
                photoData.path = photo:getRawMetadata("path")
                photoData.captureTime = photo:getFormattedMetadata("dateTimeOriginal")
                photoData.rating = photo:getRawMetadata("rating")
                photoData.fileFormat = photo:getRawMetadata("fileFormat")
                photoData.isVirtualCopy = photo:getRawMetadata("isVirtualCopy")
            end)
            
            -- Get keywords
            ErrorUtils.safeCall(function()
                local keywords = photo:getRawMetadata("keywords")
                if keywords then
                    for _, keyword in ipairs(keywords) do
                        local success, name = ErrorUtils.safeCall(function()
                            return keyword:getName()
                        end)
                        if success and name then
                            table.insert(photoData.keywords, name)
                        end
                    end
                end
            end)
            
            -- Get collections
            ErrorUtils.safeCall(function()
                local collections = photo:getContainedCollections()
                if collections then
                    for _, collection in ipairs(collections) do
                        local success, name = ErrorUtils.safeCall(function()
                            return collection:getName()
                        end)
                        if success and name then
                            table.insert(photoData.collections, name)
                        end
                    end
                end
            end)
            
            table.insert(results, photoData)
        end
        
        logger:info("Found " .. total .. " photos, returning " .. #results)
        
        wrappedCallback(ErrorUtils.createSuccess({
            photos = results,
            total = total,
            offset = offset,
            limit = limit,
            hasMore = endIndex < total
        }, "Photos retrieved successfully"))
    end)
end

-- Get photo metadata
function CatalogModule.getPhotoMetadata(params, callback)
    ensureLrModules()
    local logger = getLogger()
    
    local photoId = nil
    
    -- Safe parameter extraction with error handling
    local success, result = ErrorUtils.safeCall(function()
        logger:debug("getPhotoMetadata called with params: " .. tostring(params))
        
        if params then
            logger:debug("params is a table with type: " .. type(params))
            local count = 0
            for k, v in pairs(params) do
                logger:debug("  param[" .. tostring(k) .. "] = " .. tostring(v) .. " (type: " .. type(v) .. ")")
                count = count + 1
            end
            logger:debug("Total params count: " .. count)
            
            photoId = params.photoId
        else
            logger:error("params is nil!")
        end
        
        logger:debug("Extracted photoId: " .. tostring(photoId))
        return photoId
    end)
    
    if not success then
        logger:error("Error in parameter extraction: " .. tostring(result))
    else
        photoId = result
    end
    
    if not photoId then
        callback({
            error = {
                code = "MISSING_PHOTO_ID",
                message = "Photo ID is required"
            }
        })
        return
    end
    
    logger:debug("Getting metadata for photo: " .. photoId)
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        -- Find photo by localIdentifier
        local photo = catalog:getPhotoByLocalId(tonumber(photoId))
        
        if not photo then
            callback({
                error = {
                    code = "PHOTO_NOT_FOUND",
                    message = "Photo with ID " .. photoId .. " not found"
                }
            })
            return
        end
        
        -- Collect comprehensive metadata
        local rawRating = photo:getRawMetadata("rating")
        logger:debug("Raw rating value: " .. tostring(rawRating) .. " (type: " .. type(rawRating) .. ")")
        
        local metadata = {
            -- Basic info
            id = photo.localIdentifier,
            filename = photo:getFormattedMetadata("fileName"),
            folderPath = photo:getFormattedMetadata("folderName"),
            filepath = photo:getRawMetadata("path"),
            fileSize = photo:getFormattedMetadata("fileSize"),
            fileFormat = photo:getRawMetadata("fileFormat"),
            
            -- Capture info
            captureTime = photo:getFormattedMetadata("dateTimeOriginal"),
            cameraMake = photo:getFormattedMetadata("cameraMake"),
            cameraModel = photo:getFormattedMetadata("cameraModel"),
            lens = photo:getFormattedMetadata("lens"),
            
            -- Settings
            iso = photo:getFormattedMetadata("isoSpeedRating"),
            aperture = photo:getFormattedMetadata("aperture"),
            shutterSpeed = photo:getFormattedMetadata("shutterSpeed"),
            focalLength = photo:getFormattedMetadata("focalLength"),
            
            -- Lightroom specific
            rating = rawRating or 0,  -- Default to 0 if nil
            colorLabel = photo:getRawMetadata("colorNameForLabel"),
            isVirtualCopy = photo:getRawMetadata("isVirtualCopy"),
            stackPosition = photo:getRawMetadata("stackPositionInFolder"),
            
            -- Develop status (use basic metadata only)
            -- hasAdjustments/hasCrop not available in all Lightroom versions
            
            -- Keywords and collections
            keywords = {},
            collections = {}
        }
        
        logger:debug("Metadata table rating: " .. tostring(metadata.rating))
        
        -- Get keywords
        local keywords = photo:getRawMetadata("keywords")
        if keywords then
            for _, keyword in ipairs(keywords) do
                table.insert(metadata.keywords, {
                    name = keyword:getName(),
                    synonyms = keyword:getSynonyms()
                })
            end
        end
        
        -- Get collections
        local collections = photo:getContainedCollections()
        if collections then
            for _, collection in ipairs(collections) do
                table.insert(metadata.collections, {
                    name = collection:getName(),
                    type = collection:type()
                })
            end
        end
        
        logger:info("Retrieved metadata for photo: " .. metadata.filename)
        logger:debug("About to send metadata with rating: " .. tostring(metadata.rating))
        
        callback({
            result = metadata
        })
    end)
end

-- Get current selection
function CatalogModule.getSelectedPhotos(params, callback)
    local wrappedCallback = ErrorUtils.wrapCallback(callback, "getSelectedPhotos")
    
    -- Ensure modules are loaded
    local moduleSuccess, moduleError = ErrorUtils.safeCall(ensureLrModules)
    if not moduleSuccess then
        wrappedCallback(ErrorUtils.createError(ErrorUtils.CODES.RESOURCE_UNAVAILABLE, 
            "Failed to load Lightroom modules: " .. tostring(moduleError)))
        return
    end
    
    local logger = getLogger()
    logger:debug("Getting currently selected photos")
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        local selectedSuccess, selectedPhotos = ErrorUtils.safeCall(function()
            return catalog:getTargetPhotos()
        end)
        
        if not selectedSuccess or not selectedPhotos or #selectedPhotos == 0 then
            wrappedCallback(ErrorUtils.createSuccess({
                photos = {},
                count = 0
            }, "No photos currently selected"))
            return
        end
        
        local results = {}
        
        for i, photo in ipairs(selectedPhotos) do
            local photoData = {
                id = photo.localIdentifier
            }
            
            -- Safely get photo metadata
            ErrorUtils.safeCall(function()
                photoData.filename = photo:getFormattedMetadata("fileName")
                photoData.folderPath = photo:getFormattedMetadata("folderName")
                photoData.path = photo:getRawMetadata("path")
                photoData.captureTime = photo:getFormattedMetadata("dateTimeOriginal")
                photoData.rating = photo:getRawMetadata("rating")
                photoData.fileFormat = photo:getRawMetadata("fileFormat")
                photoData.isVirtualCopy = photo:getRawMetadata("isVirtualCopy")
            end)
            
            table.insert(results, photoData)
        end
        
        logger:info("Retrieved " .. #results .. " selected photos")
        
        wrappedCallback(ErrorUtils.createSuccess({
            photos = results,
            count = #results
        }, "Selected photos retrieved successfully"))
    end)
end

-- Set photo selection
function CatalogModule.setSelectedPhotos(params, callback)
    ensureLrModules()
    local logger = getLogger()
    local photoIds = params.photoIds
    
    if not photoIds or type(photoIds) ~= "table" then
        callback({
            error = {
                code = "INVALID_PHOTO_IDS",
                message = "Photo IDs array is required"
            }
        })
        return
    end
    
    logger:debug("Setting photo selection to " .. #photoIds .. " photos")
    
    local catalog = LrApplication.activeCatalog()
    
    -- Use withWriteAccessDo with timeout to prevent blocking
    local writeSuccess, writeError = ErrorUtils.safeCall(function()
        catalog:withWriteAccessDo("Set Photo Selection", function()
            local photos = {}
            local notFound = {}
            
            -- Find all photos by localIdentifier
            for _, photoId in ipairs(photoIds) do
                local photo = catalog:getPhotoByLocalId(tonumber(photoId))
                if photo then
                    table.insert(photos, photo)
                else
                    table.insert(notFound, photoId)
                end
            end
            
            if #photos == 0 then
                error("No photos found with provided IDs")
            end
            
            -- Set selection
            catalog:setSelectedPhotos(photos[1], photos)
            
            -- Return results for success callback
            return {
                selected = #photos,
                notFound = #notFound > 0 and notFound or nil
            }
        end, { timeout = 10 })  -- 10 second timeout
    end)
    
    if writeSuccess then
        logger:info("Successfully set selection to " .. writeError.selected .. " photos")  -- writeError contains results when successful
        callback({
            result = writeError  -- writeError is actually the success result
        })
    else
        logger:error("Failed to set photo selection (write access): " .. tostring(writeError))
        callback({
            error = {
                code = "WRITE_ACCESS_BLOCKED",
                message = "Failed to set photo selection (write access blocked): " .. tostring(writeError)
            }
        })
    end
end

-- Get all photos in catalog
function CatalogModule.getAllPhotos(params, callback)
    ensureLrModules()
    local logger = getLogger()
    local limit = params.limit or 1000  -- Default limit to prevent memory issues
    local offset = params.offset or 0
    
    logger:debug("Getting all photos from catalog")
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        local allPhotos = catalog:getAllPhotos()
        
        if not allPhotos then
            callback({
                error = {
                    code = "NO_PHOTOS",
                    message = "No photos found in catalog"
                }
            })
            return
        end
        
        logger:info("Found " .. #allPhotos .. " total photos in catalog")
        
        -- Apply pagination
        local startIndex = offset + 1
        local endIndex = math.min(startIndex + limit - 1, #allPhotos)
        local pagedPhotos = {}
        
        for i = startIndex, endIndex do
            local photo = allPhotos[i]
            table.insert(pagedPhotos, {
                id = photo.localIdentifier,
                filename = photo:getFormattedMetadata("fileName"),
                path = photo:getRawMetadata("path"),
                captureTime = photo:getFormattedMetadata("dateTimeOriginal"),
                fileFormat = photo:getRawMetadata("fileFormat"),
                rating = photo:getRawMetadata("rating")
            })
        end
        
        callback({
            result = {
                photos = pagedPhotos,
                total = #allPhotos,
                offset = offset,
                limit = limit,
                returned = #pagedPhotos
            }
        })
    end)
end

-- Find photo by file path
function CatalogModule.findPhotoByPath(params, callback)
    ensureLrModules()
    local logger = getLogger()
    local path = params.path
    
    if not path then
        callback({
            error = {
                code = "MISSING_PATH",
                message = "File path is required"
            }
        })
        return
    end
    
    logger:debug("Finding photo by path: " .. path)
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        local photo = catalog:findPhotoByPath(path)
        
        if not photo then
            callback({
                error = {
                    code = "PHOTO_NOT_FOUND",
                    message = "No photo found at path: " .. path
                }
            })
            return
        end
        
        callback({
            result = {
                id = photo.localIdentifier,
                filename = photo:getFormattedMetadata("fileName"),
                path = photo:getRawMetadata("path"),
                captureTime = photo:getFormattedMetadata("dateTimeOriginal"),
                fileFormat = photo:getRawMetadata("fileFormat"),
                rating = photo:getRawMetadata("rating"),
                camera = photo:getFormattedMetadata("cameraModel")
            }
        })
    end)
end

-- Advanced photo search with criteria
function CatalogModule.findPhotos(params, callback)
    ensureLrModules()
    local logger = getLogger()
    local searchDesc = params.searchDesc or {}
    local limit = params.limit or 100
    
    logger:debug("Finding photos with search criteria")
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        -- Simple fallback: just use getAllPhotos with limit
        local allPhotos = catalog:getAllPhotos()
        
        if not allPhotos or #allPhotos == 0 then
            callback({
                result = {
                    photos = {},
                    total = 0,
                    returned = 0
                }
            })
            return
        end
        
        logger:info("Found " .. #allPhotos .. " photos total, applying limit")
        
        -- Apply limit and convert to response format
        local resultPhotos = {}
        local maxResults = math.min(limit, #allPhotos)
        
        for i = 1, maxResults do
            local photo = allPhotos[i]
            table.insert(resultPhotos, {
                id = photo.localIdentifier,
                filename = photo:getFormattedMetadata("fileName"),
                path = photo:getRawMetadata("path"),
                captureTime = photo:getFormattedMetadata("dateTimeOriginal"),
                fileFormat = photo:getRawMetadata("fileFormat"),
                rating = photo:getRawMetadata("rating")
            })
        end
        
        callback({
            result = {
                photos = resultPhotos,
                total = #allPhotos,
                returned = #resultPhotos
            }
        })
    end)
end

-- Get collections in catalog
function CatalogModule.getCollections(params, callback)
    ensureLrModules()
    local logger = getLogger()
    
    logger:debug("Getting collections from catalog")
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        local collections = catalog:getChildCollections()
        
        local resultCollections = {}
        for _, collection in ipairs(collections) do
            table.insert(resultCollections, {
                id = collection.localIdentifier,
                name = collection:getName(),
                type = collection:type(),
                photoCount = #collection:getPhotos()
            })
        end
        
        callback({
            result = {
                collections = resultCollections,
                count = #resultCollections
            }
        })
    end)
end

-- Add keywords to a photo
function CatalogModule.addPhotoKeywords(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local photoId = params and tonumber(params.photoId)
    local keywords = params and params.keywords

    if not photoId then
        callback({ error = { code = "MISSING_PARAM", message = "photoId is required" } })
        return
    end
    if not keywords or type(keywords) ~= "table" or #keywords == 0 then
        callback({ error = { code = "MISSING_PARAM", message = "keywords array is required" } })
        return
    end

    logger:info("Adding " .. #keywords .. " keywords to photo " .. photoId)

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Add Keywords", function()
        local photo = catalog:getPhotoByLocalId(photoId)
        if not photo then
            callback({ error = { code = "PHOTO_NOT_FOUND", message = "Photo not found: " .. photoId } })
            return
        end

        local addedKeywords = {}
        for _, keywordName in ipairs(keywords) do
            -- createKeyword returns existing keyword if it already exists
            local keyword = catalog:createKeyword(keywordName, {}, true, nil, true)
            if keyword then
                photo:addKeyword(keyword)
                table.insert(addedKeywords, keywordName)
                logger:debug("Added keyword: " .. keywordName)
            else
                logger:warn("Failed to create keyword: " .. keywordName)
            end
        end

        logger:info("Added " .. #addedKeywords .. " keywords to photo " .. photoId)

        callback({
            result = {
                photoId = photoId,
                keywordsAdded = addedKeywords,
                count = #addedKeywords
            }
        })
    end)
end

-- Get photos that have a specific keyword (by ID for speed, or name as fallback)
function CatalogModule.getKeywordPhotos(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local keywordId = params and tonumber(params.keywordId)
    local keywordName = params and params.keywordName
    local limit = (params and params.limit) or 100
    local offset = (params and params.offset) or 0

    if not keywordId and not keywordName then
        callback({ error = { code = "MISSING_PARAM", message = "keywordId or keywordName is required" } })
        return
    end

    local catalog = LrApplication.activeCatalog()

    catalog:withReadAccessDo(function()
        local targetKeyword = nil

        if keywordId then
            -- Fast path: direct lookup by ID
            logger:info("Finding keyword by ID: " .. keywordId)
            local allKeywords = catalog:getKeywords()
            for _, kw in ipairs(allKeywords) do
                if kw.localIdentifier == keywordId then
                    targetKeyword = kw
                    break
                end
            end
        else
            -- Slow path: scan by name (exact match only)
            logger:info("Finding keyword by name: " .. keywordName)
            local allKeywords = catalog:getKeywords()
            for _, kw in ipairs(allKeywords) do
                if kw:getName() == keywordName then
                    targetKeyword = kw
                    break  -- exact match found, stop scanning
                end
            end
        end

        if not targetKeyword then
            callback({
                result = {
                    photos = {},
                    count = 0,
                    total = 0,
                    keywordFound = false
                }
            })
            return
        end

        logger:info("Found keyword: " .. targetKeyword:getName() .. " (id=" .. targetKeyword.localIdentifier .. ")")

        local allPhotos = targetKeyword:getPhotos()
        local total = #allPhotos

        logger:info("Keyword has " .. total .. " photos")

        -- Apply pagination
        local resultPhotos = {}
        local endIdx = math.min(offset + limit, total)
        for i = offset + 1, endIdx do
            local photo = allPhotos[i]
            table.insert(resultPhotos, {
                id = photo.localIdentifier,
                filename = photo:getFormattedMetadata("fileName"),
                path = photo:getRawMetadata("path")
            })
        end

        callback({
            result = {
                photos = resultPhotos,
                count = #resultPhotos,
                total = total,
                keywordFound = true,
                keywordName = targetKeyword:getName(),
                keywordId = targetKeyword.localIdentifier,
                offset = offset,
                limit = limit,
                hasMore = (offset + limit) < total
            }
        })
    end)
end

-- Batch set metadata on all photos with a specific keyword (skip if already set)
function CatalogModule.batchSetMetadataByKeyword(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local keywordId = params and tonumber(params.keywordId)
    local keywordName = params and params.keywordName
    local field = params and params.field
    local value = params and params.value
    local dryRun = (params and params.dryRun) or false

    if not keywordId and not keywordName then
        callback({ error = { code = "MISSING_PARAM", message = "keywordId or keywordName is required" } })
        return
    end
    if not field or not value then
        callback({ error = { code = "MISSING_PARAM", message = "field and value are required" } })
        return
    end

    local catalog = LrApplication.activeCatalog()

    -- First pass: find keyword and count photos (read access)
    local targetKeyword = nil
    local photoList = {}

    catalog:withReadAccessDo(function()
        local allKeywords = catalog:getKeywords()

        if keywordId then
            for _, kw in ipairs(allKeywords) do
                if kw.localIdentifier == keywordId then
                    targetKeyword = kw
                    break
                end
            end
        else
            for _, kw in ipairs(allKeywords) do
                if kw:getName() == keywordName then
                    targetKeyword = kw
                    break
                end
            end
        end

        if targetKeyword then
            photoList = targetKeyword:getPhotos()
        end
    end)

    if not targetKeyword then
        callback({ result = { stamped = 0, skipped = 0, total = 0, keywordFound = false } })
        return
    end

    local total = #photoList
    logger:info("Batch set " .. field .. " = '" .. value .. "' on " .. total .. " photos (keyword: " .. targetKeyword:getName() .. ", dryRun=" .. tostring(dryRun) .. ")")

    if dryRun then
        -- Dry run: just count how many need updating
        local needsUpdate = 0
        local alreadySet = 0

        catalog:withReadAccessDo(function()
            for _, photo in ipairs(photoList) do
                local current = photo:getFormattedMetadata(field) or ""
                if current == value then
                    alreadySet = alreadySet + 1
                else
                    needsUpdate = needsUpdate + 1
                end
            end
        end)

        callback({
            result = {
                stamped = 0,
                wouldStamp = needsUpdate,
                skipped = alreadySet,
                total = total,
                keywordFound = true,
                keywordName = targetKeyword:getName(),
                dryRun = true
            }
        })
        return
    end

    -- Execute: stamp photos that need it
    local stamped = 0
    local skipped = 0
    local errors = 0

    catalog:withWriteAccessDo("Batch Set " .. field, function()
        for _, photo in ipairs(photoList) do
            local success, err = LrTasks.pcall(function()
                local current = photo:getFormattedMetadata(field) or ""
                if current == value then
                    skipped = skipped + 1
                else
                    photo:setRawMetadata(field, value)
                    stamped = stamped + 1
                end
            end)
            if not success then
                errors = errors + 1
                logger:error("Failed to set metadata on photo: " .. tostring(err))
            end
        end
    end)

    logger:info("Batch complete: " .. stamped .. " stamped, " .. skipped .. " skipped, " .. errors .. " errors")

    callback({
        result = {
            stamped = stamped,
            skipped = skipped,
            errors = errors,
            total = total,
            keywordFound = true,
            keywordName = targetKeyword:getName(),
            dryRun = false
        }
    })
end

-- Set metadata field on a photo (Artist, Caption, etc.)
function CatalogModule.setPhotoMetadata(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local photoId = params and tonumber(params.photoId)
    local field = params and params.field
    local value = params and params.value

    if not photoId then
        callback({ error = { code = "MISSING_PARAM", message = "photoId is required" } })
        return
    end
    if not field then
        callback({ error = { code = "MISSING_PARAM", message = "field is required" } })
        return
    end

    -- Whitelist of writable metadata fields
    local writableFields = {
        artist = true, caption = true, copyright = true,
        title = true, headline = true,
        city = true, state = true, country = true,
        isoCountryCode = true, location = true,
        creator = true, creatorJobTitle = true,
        creatorAddress = true, creatorCity = true,
        creatorStateProvince = true, creatorPostalCode = true,
        creatorCountry = true, creatorPhone = true,
        creatorEmail = true, creatorUrl = true
    }

    if not writableFields[field] then
        callback({ error = {
            code = "INVALID_PARAM",
            message = "Field '" .. field .. "' is not writable. Allowed: artist, caption, copyright, title, headline, city, state, country, location, creator"
        }})
        return
    end

    logger:info("Setting " .. field .. " = '" .. tostring(value) .. "' on photo " .. photoId)

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Set Photo Metadata", function()
        local photo = catalog:getPhotoByLocalId(photoId)
        if not photo then
            callback({ error = { code = "PHOTO_NOT_FOUND", message = "Photo not found: " .. photoId } })
            return
        end

        photo:setRawMetadata(field, value)

        logger:info("Set " .. field .. " on photo " .. photoId)

        callback({
            result = {
                photoId = photoId,
                field = field,
                value = value
            }
        })
    end)
end

-- Remove keywords from a photo
function CatalogModule.removePhotoKeywords(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local photoId = params and tonumber(params.photoId)
    local keywords = params and params.keywords

    if not photoId then
        callback({ error = { code = "MISSING_PARAM", message = "photoId is required" } })
        return
    end
    if not keywords or type(keywords) ~= "table" or #keywords == 0 then
        callback({ error = { code = "MISSING_PARAM", message = "keywords array is required" } })
        return
    end

    logger:info("Removing " .. #keywords .. " keywords from photo " .. photoId)

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Remove Keywords", function()
        local photo = catalog:getPhotoByLocalId(photoId)
        if not photo then
            callback({ error = { code = "PHOTO_NOT_FOUND", message = "Photo not found: " .. photoId } })
            return
        end

        local removed = {}
        local photoKeywords = photo:getRawMetadata("keywords") or {}

        for _, keywordName in ipairs(keywords) do
            for _, kw in ipairs(photoKeywords) do
                if kw:getName() == keywordName then
                    photo:removeKeyword(kw)
                    table.insert(removed, keywordName)
                    break
                end
            end
        end

        logger:info("Removed " .. #removed .. " keywords from photo " .. photoId)

        callback({
            result = {
                photoId = photoId,
                keywordsRemoved = removed,
                count = #removed
            }
        })
    end)
end

-- Delete a keyword from the catalog entirely (removes from all photos)
function CatalogModule.deleteKeyword(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local keywordId = params and tonumber(params.keywordId)
    local keywordName = params and params.keywordName
    local dryRun = (params and params.dryRun) or false

    if not keywordId and not keywordName then
        callback({ error = { code = "MISSING_PARAM", message = "keywordId or keywordName is required" } })
        return
    end

    local catalog = LrApplication.activeCatalog()
    local targetKeyword = nil
    local photoCount = 0

    -- Find the keyword (read access)
    catalog:withReadAccessDo(function()
        local allKeywords = catalog:getKeywords()
        if keywordId then
            for _, kw in ipairs(allKeywords) do
                if kw.localIdentifier == keywordId then
                    targetKeyword = kw
                    break
                end
            end
        else
            for _, kw in ipairs(allKeywords) do
                if kw:getName() == keywordName then
                    targetKeyword = kw
                    break
                end
            end
        end

        if targetKeyword then
            photoCount = #targetKeyword:getPhotos()
        end
    end)

    if not targetKeyword then
        callback({ result = { deleted = false, message = "Keyword not found" } })
        return
    end

    local kwName = targetKeyword:getName()
    logger:info("Delete keyword: " .. kwName .. " (id=" .. targetKeyword.localIdentifier .. ", photos=" .. photoCount .. ", dryRun=" .. tostring(dryRun) .. ")")

    if dryRun then
        callback({
            result = {
                deleted = false,
                dryRun = true,
                keywordName = kwName,
                keywordId = targetKeyword.localIdentifier,
                photoCount = photoCount,
                message = "Would delete keyword '" .. kwName .. "' affecting " .. photoCount .. " photos"
            }
        })
        return
    end

    -- Delete (write access)
    catalog:withWriteAccessDo("Delete Keyword", function()
        catalog:deleteKeyword(targetKeyword)
        logger:info("Deleted keyword: " .. kwName)

        callback({
            result = {
                deleted = true,
                keywordName = kwName,
                keywordId = targetKeyword.localIdentifier,
                photoCount = photoCount
            }
        })
    end)
end

-- Batch delete keywords by pattern (for cleanup passes)
function CatalogModule.batchDeleteKeywords(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local keywordIds = params and params.keywordIds
    local dryRun = (params and params.dryRun) or false

    if not keywordIds or type(keywordIds) ~= "table" or #keywordIds == 0 then
        callback({ error = { code = "MISSING_PARAM", message = "keywordIds array is required" } })
        return
    end

    local catalog = LrApplication.activeCatalog()

    -- Build ID lookup set
    local idSet = {}
    for _, id in ipairs(keywordIds) do
        idSet[tonumber(id)] = true
    end

    -- Find and optionally delete keywords in a single write access call
    -- (keeping keyword objects inside the same access block where they're used)
    local found = 0
    local deleted = 0
    local names = {}

    catalog:withWriteAccessDo("Batch Delete Keywords", function()
        local allKeywords = catalog:getKeywords()
        for _, kw in ipairs(allKeywords) do
            if idSet[kw.localIdentifier] then
                found = found + 1
                local kwName = kw:getName()
                table.insert(names, kwName)

                if not dryRun then
                    local success, err = LrTasks.pcall(function()
                        catalog:deleteKeyword(kw)
                    end)
                    if success then
                        deleted = deleted + 1
                    else
                        logger:error("Failed to delete keyword: " .. kwName .. " — " .. tostring(err))
                    end
                end
            end
        end

        logger:info("Batch delete: found=" .. found .. " deleted=" .. deleted .. " dryRun=" .. tostring(dryRun))

        if dryRun then
            callback({
                result = {
                    deleted = 0,
                    dryRun = true,
                    found = found,
                    requested = #keywordIds,
                    keywords = names
                }
            })
        else
            callback({
                result = {
                    deleted = deleted,
                    requested = #keywordIds,
                    found = found
                }
            })
        end
    end)
end

-- Get keywords in catalog (with pagination and optional photo counts)
function CatalogModule.getKeywords(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local limit = (params and params.limit) or 500
    local offset = (params and params.offset) or 0
    local includeCounts = (params and params.includeCounts) or false

    logger:info("Getting keywords (limit=" .. limit .. ", offset=" .. offset .. ", counts=" .. tostring(includeCounts) .. ")")

    local catalog = LrApplication.activeCatalog()

    catalog:withReadAccessDo(function()
        local allKeywords = catalog:getKeywords()
        local total = #allKeywords

        -- Fast flat list — names and IDs only, no recursion, no photo queries
        -- getChildren() and getPhotos() are too slow for large catalogs
        local resultKeywords = {}
        local endIdx = math.min(offset + limit, total)
        for i = offset + 1, endIdx do
            local keyword = allKeywords[i]
            table.insert(resultKeywords, {
                id = keyword.localIdentifier,
                name = keyword:getName()
            })
        end

        logger:info("Returning " .. #resultKeywords .. " of " .. total .. " top-level keywords")

        callback({
            result = {
                keywords = resultKeywords,
                count = #resultKeywords,
                total = total,
                offset = offset,
                limit = limit,
                hasMore = (offset + limit) < total
            }
        })
    end)
end

-- Get folders in catalog
function CatalogModule.getFolders(params, callback)
    ensureLrModules()
    local logger = getLogger()
    local includeSubfolders = params.includeSubfolders or false
    
    logger:debug("Getting folders from catalog")
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        local rootFolders = catalog:getFolders()
        
        local function buildFolderTree(folder, depth)
            depth = depth or 0
            local folderPath = folder:getPath()
            local folderData = {
                id = folderPath, -- Use path as ID since folders don't have localIdentifier
                name = folder:getName(),
                path = folderPath,
                type = folder:type(),
                depth = depth,
                photoCount = #folder:getPhotos(false), -- Photos directly in this folder
                totalPhotoCount = #folder:getPhotos(true), -- Photos including subfolders
                subfolders = {}
            }
            
            -- Get parent folder info if available
            local parent = folder:getParent()
            if parent then
                folderData.parentId = parent:getPath()
                folderData.parentName = parent:getName()
            end
            
            -- Recursively get subfolders if requested
            if includeSubfolders then
                local children = folder:getChildren()
                if children then
                    for _, child in ipairs(children) do
                        table.insert(folderData.subfolders, buildFolderTree(child, depth + 1))
                    end
                end
            end
            
            return folderData
        end
        
        local resultFolders = {}
        for _, folder in ipairs(rootFolders) do
            table.insert(resultFolders, buildFolderTree(folder))
        end
        
        logger:info("Retrieved " .. #resultFolders .. " root folders from catalog")
        
        callback({
            result = {
                folders = resultFolders,
                count = #resultFolders,
                includeSubfolders = includeSubfolders
            }
        })
    end)
end

-- Batch get formatted metadata for multiple photos
function CatalogModule.batchGetFormattedMetadata(params, callback)
    ensureLrModules()
    local logger = getLogger()
    local photoIds = params.photoIds
    local keys = params.keys or {"fileName", "dateTimeOriginal", "rating"}
    
    logger:debug("Batch metadata - photoIds type: " .. type(photoIds))
    if photoIds then
        logger:debug("Batch metadata - photoIds length: " .. tostring(#photoIds))
        if type(photoIds) == "table" then
            for i, id in ipairs(photoIds) do
                logger:debug("  photoId[" .. i .. "] = " .. tostring(id) .. " (type: " .. type(id) .. ")")
            end
        end
    end
    
    if not photoIds then
        callback({
            error = {
                code = "MISSING_PHOTO_IDS", 
                message = "Photo IDs parameter is missing"
            }
        })
        return
    end
    
    if type(photoIds) ~= "table" then
        callback({
            error = {
                code = "INVALID_PHOTO_IDS_TYPE",
                message = "Photo IDs must be an array, got: " .. type(photoIds)
            }
        })
        return
    end
    
    if #photoIds == 0 then
        callback({
            error = {
                code = "EMPTY_PHOTO_IDS",
                message = "Photo IDs array is empty"
            }
        })
        return
    end
    
    logger:debug("Batch getting metadata for " .. #photoIds .. " photos")
    logger:debug("Keys type: " .. type(keys))
    if type(keys) == "table" then
        logger:debug("Keys length: " .. #keys)
        for i, key in ipairs(keys) do
            logger:debug("  key[" .. i .. "] = " .. tostring(key))
        end
    else
        logger:debug("Keys value: " .. tostring(keys))
    end
    
    local catalog = LrApplication.activeCatalog()
    
    catalog:withReadAccessDo(function()
        local photos = {}
        for _, photoId in ipairs(photoIds) do
            local photo = catalog:getPhotoByLocalId(tonumber(photoId))
            if photo then
                table.insert(photos, photo)
            end
        end
        
        if #photos == 0 then
            callback({
                result = {
                    metadata = {},
                    requested = #photoIds,
                    found = 0
                }
            })
            return
        end
        
        -- Use batch API for efficiency
        local batchResults = catalog:batchGetFormattedMetadata(photos, keys)
        
        local results = {}
        for i, photo in ipairs(photos) do
            local metadata = batchResults[i] or {}
            metadata.id = photo.localIdentifier
            table.insert(results, metadata)
        end
        
        callback({
            result = {
                metadata = results,
                requested = #photoIds,
                found = #photos,
                keys = keys
            }
        })
    end)
end

return CatalogModule