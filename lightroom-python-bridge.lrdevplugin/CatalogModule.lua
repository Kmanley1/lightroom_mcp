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

        -- Apply criteria filter (criteria was previously extracted but never used).
        -- Filters: keyword (name match), rating.min/max, fileFormat (JPEG normalized
        -- to JPG, case-insensitive), captureDate.after/before (YYYY-MM-DD).
        local matched
        if not criteria or not next(criteria) then
            matched = allPhotos
        else
            matched = {}

            -- Normalize fileFormat once
            local fmtFilter = nil
            if criteria.fileFormat and criteria.fileFormat ~= "" then
                local upper = string.upper(criteria.fileFormat)
                if upper == "JPEG" then upper = "JPG" end
                fmtFilter = upper
            end

            -- Parse date strings to Cocoa time once
            local dateAfter, dateBefore = nil, nil
            if criteria.captureDate then
                local LrDate = import 'LrDate'
                if criteria.captureDate.after then
                    local y, mo, d = criteria.captureDate.after:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
                    if y then
                        dateAfter = LrDate.timeFromComponents(tonumber(y), tonumber(mo), tonumber(d), 0, 0, 0, "local")
                    end
                end
                if criteria.captureDate.before then
                    local y, mo, d = criteria.captureDate.before:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
                    if y then
                        dateBefore = LrDate.timeFromComponents(tonumber(y), tonumber(mo), tonumber(d), 23, 59, 59, "local")
                    end
                end
            end

            for _, photo in ipairs(allPhotos) do
                local include = true

                if include and fmtFilter then
                    local f = photo:getRawMetadata("fileFormat")
                    if not f or string.upper(tostring(f)) ~= fmtFilter then
                        include = false
                    end
                end

                if include and criteria.rating then
                    local rating = photo:getRawMetadata("rating") or 0
                    if criteria.rating.min and rating < criteria.rating.min then
                        include = false
                    end
                    if include and criteria.rating.max and rating > criteria.rating.max then
                        include = false
                    end
                end

                if include and (dateAfter or dateBefore) then
                    local captureTime = photo:getRawMetadata("dateTimeOriginal")
                    if not captureTime then
                        include = false
                    else
                        if dateAfter and captureTime < dateAfter then include = false end
                        if include and dateBefore and captureTime > dateBefore then include = false end
                    end
                end

                if include and criteria.keyword and criteria.keyword ~= "" then
                    local found = false
                    local keywords = photo:getRawMetadata("keywords")
                    if keywords then
                        for _, kw in ipairs(keywords) do
                            local ok, name = ErrorUtils.safeCall(function()
                                return kw:getName()
                            end)
                            if ok and name == criteria.keyword then
                                found = true
                                break
                            end
                        end
                    end
                    if not found then include = false end
                end

                if include then
                    table.insert(matched, photo)
                end
            end
        end

        local results = {}
        local total = #matched
        local startIndex = offset + 1
        local endIndex = math.min(offset + limit, total)

        for i = startIndex, endIndex do
            local photo = matched[i]
            
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

-- Recursive walker: find a collection (smart or regular) by localIdentifier.
-- Searches top-level child collections + descends into collection sets.
local function findCollectionById(catalog, targetId)
    local function walk(items)
        for _, item in ipairs(items) do
            if item.localIdentifier == targetId then
                return item
            end
            -- Collection sets expose getChildCollections() and getChildCollectionSets()
            if item.type and item:type() == "LrCollectionSet" then
                local found = walk(item:getChildCollections())
                if found then return found end
                local foundInSet = walk(item:getChildCollectionSets())
                if foundInSet then return foundInSet end
            end
        end
        return nil
    end
    local hit = walk(catalog:getChildCollections())
    if hit then return hit end
    return walk(catalog:getChildCollectionSets())
end

-- Create a smart collection with searchDesc criteria.
-- searchDesc: same shape as catalog:findPhotos {searchDesc=...}
--   simple form: { criteria = "rating", operation = ">=", value = 3 }
--   compound:    { criteria = { {...}, {...} }, combine = "intersect" }
function CatalogModule.createSmartCollection(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local name = params and params.name
    local searchDesc = params and params.searchDesc
    local parentId = params and tonumber(params.parentId)

    if type(name) ~= "string" or name == "" then
        callback({ error = { code = "MISSING_PARAM", message = "name is required" } })
        return
    end
    if type(searchDesc) ~= "table" then
        callback({ error = { code = "MISSING_PARAM", message = "searchDesc is required (object)" } })
        return
    end

    local catalog = LrApplication.activeCatalog()

    -- Resolve parent (read-only) before opening the write block.
    local parent = nil
    if parentId then
        local found
        catalog:withReadAccessDo(function()
            found = findCollectionById(catalog, parentId)
        end)
        if not found then
            callback({ error = { code = "PHOTO_NOT_FOUND", message = "Parent collection set not found: " .. parentId } })
            return
        end
        parent = found
    end

    -- LrC SDK constraint: cannot read localIdentifier/getName/type on a
    -- newly-created collection inside the same withWriteAccessDo block.
    -- Capture the reference in the write block, read its properties after.
    local sc
    catalog:withWriteAccessDo("Create Smart Collection", function()
        -- 4th arg `returnExisting`: idempotent on duplicate name at same level.
        sc = catalog:createSmartCollection(name, searchDesc, parent, true)
    end)

    if not sc then
        callback({ error = { code = "HANDLER_ERROR", message = "createSmartCollection returned nil" } })
        return
    end

    -- Read properties in a separate read block (write block has committed).
    catalog:withReadAccessDo(function()
        local id = sc.localIdentifier
        local resolvedName = sc:getName()
        local resolvedType = sc:type()
        logger:info("Created smart collection: " .. resolvedName .. " (id=" .. tostring(id) .. ", type=" .. tostring(resolvedType) .. ")")
        callback({
            result = {
                id = id,
                name = resolvedName,
                type = resolvedType
            }
        })
    end)
end

-- Get a smart collection's searchDesc criteria.
function CatalogModule.getSmartCollectionCriteria(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local collectionId = params and tonumber(params.collectionId)
    if not collectionId then
        callback({ error = { code = "MISSING_PARAM", message = "collectionId is required" } })
        return
    end

    local catalog = LrApplication.activeCatalog()

    catalog:withReadAccessDo(function()
        local sc = findCollectionById(catalog, collectionId)
        if not sc then
            callback({ error = { code = "PHOTO_NOT_FOUND", message = "Collection not found: " .. collectionId } })
            return
        end
        -- LrC reports type "LrCollection" for both regular and smart collections;
        -- use isSmartCollection() to differentiate.
        local isSmart = sc.isSmartCollection and sc:isSmartCollection() or false
        if not isSmart then
            callback({ error = { code = "INVALID_PARAM_VALUE", message = "Collection " .. collectionId .. " is not a smart collection" } })
            return
        end

        local searchDesc = sc:getSearchDescription()
        callback({
            result = {
                id = sc.localIdentifier,
                name = sc:getName(),
                searchDesc = searchDesc
            }
        })
    end)
end

-- Update a smart collection's searchDesc criteria.
function CatalogModule.updateSmartCollection(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local collectionId = params and tonumber(params.collectionId)
    local searchDesc = params and params.searchDesc

    if not collectionId then
        callback({ error = { code = "MISSING_PARAM", message = "collectionId is required" } })
        return
    end
    if type(searchDesc) ~= "table" then
        callback({ error = { code = "MISSING_PARAM", message = "searchDesc is required (object)" } })
        return
    end

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Update Smart Collection", function()
        local sc = findCollectionById(catalog, collectionId)
        if not sc then
            callback({ error = { code = "PHOTO_NOT_FOUND", message = "Collection not found: " .. collectionId } })
            return
        end
        local isSmart = sc.isSmartCollection and sc:isSmartCollection() or false
        if not isSmart then
            callback({ error = { code = "INVALID_PARAM_VALUE", message = "Collection " .. collectionId .. " is not a smart collection" } })
            return
        end

        sc:setSearchDescription(searchDesc)
        logger:info("Updated smart collection: " .. sc:getName() .. " (id=" .. collectionId .. ")")
        callback({
            result = {
                id = collectionId,
                name = sc:getName()
            }
        })
    end)
end

-- Delete a smart collection.
function CatalogModule.deleteSmartCollection(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local collectionId = params and tonumber(params.collectionId)
    if not collectionId then
        callback({ error = { code = "MISSING_PARAM", message = "collectionId is required" } })
        return
    end

    local catalog = LrApplication.activeCatalog()

    catalog:withWriteAccessDo("Delete Smart Collection", function()
        local sc = findCollectionById(catalog, collectionId)
        if not sc then
            callback({ error = { code = "PHOTO_NOT_FOUND", message = "Collection not found: " .. collectionId } })
            return
        end
        local isSmart = sc.isSmartCollection and sc:isSmartCollection() or false
        if not isSmart then
            callback({ error = { code = "INVALID_PARAM_VALUE", message = "Collection " .. collectionId .. " is not a smart collection (use a different tool to delete regular collections)" } })
            return
        end

        local name = sc:getName()
        sc:delete()
        logger:info("Deleted smart collection: " .. name .. " (id=" .. collectionId .. ")")
        callback({
            result = {
                id = collectionId,
                name = name,
                deleted = true
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

-- Get full keyword hierarchy as a tree
function CatalogModule.getKeywordTree(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local includeCounts = (params and params.includeCounts) or false
    local maxDepth = (params and params.maxDepth) or 10

    logger:info("Getting keyword tree (counts=" .. tostring(includeCounts) .. ", maxDepth=" .. maxDepth .. ")")

    local catalog = LrApplication.activeCatalog()

    catalog:withReadAccessDo(function()
        local function buildTree(keywords, depth)
            if depth > maxDepth then return {} end
            local result = {}
            for _, kw in ipairs(keywords) do
                local node = {
                    id = kw.localIdentifier,
                    name = kw:getName()
                }
                if includeCounts then
                    node.photoCount = #kw:getPhotos()
                end
                local children = kw:getChildren()
                if children and #children > 0 then
                    node.children = buildTree(children, depth + 1)
                end
                table.insert(result, node)
            end
            return result
        end

        local topLevel = catalog:getKeywords()
        local tree = buildTree(topLevel, 1)

        -- Count total keywords in tree
        local function countNodes(nodes)
            local count = 0
            for _, node in ipairs(nodes) do
                count = count + 1
                if node.children then
                    count = count + countNodes(node.children)
                end
            end
            return count
        end

        local totalCount = countNodes(tree)
        logger:info("Keyword tree: " .. #tree .. " top-level, " .. totalCount .. " total")

        callback({
            result = {
                keywords = tree,
                topLevelCount = #tree,
                totalCount = totalCount
            }
        })
    end)
end

-- Create a keyword in the hierarchy under an optional parent
function CatalogModule.createKeyword(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local keywordName = params and params.keywordName
    local parentId = params and params.parentId and tonumber(params.parentId)
    local dryRun = (params and params.dryRun) or false

    if not keywordName or keywordName == "" then
        callback({ error = { code = "MISSING_PARAM", message = "keywordName is required" } })
        return
    end

    logger:info("Create keyword: " .. keywordName .. " (parentId=" .. tostring(parentId) .. ", dryRun=" .. tostring(dryRun) .. ")")

    local catalog = LrApplication.activeCatalog()
    local parentKeyword = nil

    -- Find parent keyword if specified
    if parentId then
        catalog:withReadAccessDo(function()
            local function findById(keywords)
                for _, kw in ipairs(keywords) do
                    if kw.localIdentifier == parentId then
                        return kw
                    end
                    local children = kw:getChildren()
                    if children and #children > 0 then
                        local found = findById(children)
                        if found then return found end
                    end
                end
                return nil
            end
            parentKeyword = findById(catalog:getKeywords())
        end)

        if not parentKeyword then
            callback({ error = { code = "PARENT_NOT_FOUND", message = "Parent keyword not found: " .. parentId } })
            return
        end
    end

    if dryRun then
        callback({
            result = {
                created = false,
                dryRun = true,
                keywordName = keywordName,
                parentId = parentId,
                parentName = parentKeyword and parentKeyword:getName() or nil,
                message = "Would create keyword '" .. keywordName .. "'" ..
                    (parentKeyword and (" under '" .. parentKeyword:getName() .. "'") or " at top level")
            }
        })
        return
    end

    -- Create keyword (returns existing if already exists)
    local createdKeyword = nil
    catalog:withWriteAccessDo("Create Keyword", function()
        createdKeyword = catalog:createKeyword(keywordName, {}, true, parentKeyword, true)
    end)

    if not createdKeyword then
        callback({ error = { code = "CREATE_FAILED", message = "Failed to create keyword: " .. keywordName } })
        return
    end

    -- Read keyword info in separate read block
    local keywordId = nil
    catalog:withReadAccessDo(function()
        keywordId = createdKeyword.localIdentifier
    end)

    logger:info("Created keyword: " .. keywordName .. " (id=" .. tostring(keywordId) .. ")")
    callback({
        result = {
            created = true,
            keywordId = keywordId,
            keywordName = keywordName,
            parentId = parentId,
            parentName = parentKeyword and parentKeyword:getName() or nil
        }
    })
end

-- Batch stamp keywords on photos found by file path
function CatalogModule.batchStampByPath(params, callback)
    ensureLrModules()
    local logger = getLogger()

    local items = params and params.items
    local dryRun = (params and params.dryRun) or false

    if not items or type(items) ~= "table" or #items == 0 then
        callback({ error = { code = "MISSING_PARAM", message = "items array is required (each: {path, keywords})" } })
        return
    end

    logger:info("Batch stamp: " .. #items .. " items (dryRun=" .. tostring(dryRun) .. ")")

    local catalog = LrApplication.activeCatalog()
    local results = { stamped = 0, notFound = 0, errors = 0, details = {} }

    if dryRun then
        -- Read-only: check which photos exist
        catalog:withReadAccessDo(function()
            for _, item in ipairs(items) do
                local photo = catalog:findPhotoByPath(item.path, false)
                if photo then
                    results.stamped = results.stamped + 1
                else
                    results.notFound = results.notFound + 1
                    table.insert(results.details, { path = item.path, status = "not_found" })
                end
            end
        end)
        results.dryRun = true
        callback({ result = results })
        return
    end

    -- Pre-resolve all unique keyword names to keyword objects (read block)
    local allKwNames = {}
    for _, item in ipairs(items) do
        for _, kwName in ipairs(item.keywords) do
            allKwNames[kwName] = true
        end
    end

    local kwMap = {}  -- name -> keyword object
    catalog:withReadAccessDo(function()
        local function buildMap(keywords)
            for _, kw in ipairs(keywords) do
                local name = kw:getName()
                if allKwNames[name] then
                    kwMap[name] = kw
                end
                local children = kw:getChildren()
                if children and #children > 0 then
                    buildMap(children)
                end
            end
        end
        buildMap(catalog:getKeywords())
    end)

    logger:info("Pre-resolved " .. (function() local n=0; for _ in pairs(kwMap) do n=n+1 end; return n end)() .. " keywords")

    -- Stamp photos with pre-resolved keywords (write block)
    catalog:withWriteAccessDo("Batch Stamp Keywords", function()
        for _, item in ipairs(items) do
            local photo = catalog:findPhotoByPath(item.path, false)
            if photo then
                local ok = true
                for _, kwName in ipairs(item.keywords) do
                    local keyword = kwMap[kwName]
                    if not keyword then
                        -- Create at top level if not pre-resolved
                        keyword = catalog:createKeyword(kwName, {}, true, nil, true)
                    end

                    if keyword then
                        photo:addKeyword(keyword)
                    else
                        ok = false
                        logger:warn("Failed to find/create keyword: " .. kwName)
                    end
                end
                if ok then
                    results.stamped = results.stamped + 1
                else
                    results.errors = results.errors + 1
                end
            else
                results.notFound = results.notFound + 1
            end
        end
    end)

    logger:info("Batch stamp complete: " .. results.stamped .. " stamped, " .. results.notFound .. " not found, " .. results.errors .. " errors")
    callback({ result = results })
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