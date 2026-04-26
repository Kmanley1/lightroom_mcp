"""
Catalog server module for photo management
Essential for photo selection and metadata access
"""
from typing import Dict, Any, Optional, List, Union
from mcp_server.shared.base import LightroomServerModule
import logging

logger = logging.getLogger(__name__)

class CatalogServer(LightroomServerModule):
    """Photo catalog operations"""
    
    @property
    def name(self) -> str:
        return "Lightroom Catalog Tools"
    
    @property
    def prefix(self) -> str:
        return "catalog"
    
    def _setup_tools(self):
        """Register catalog tools"""
        
        @self.server.tool
        async def catalog_get_selected_photos() -> Dict[str, Any]:
            """
            Get currently selected photos in Lightroom.
            
            Essential for AI agents to know which photo(s) they're working on.
            
            Returns:
                Selected photos with metadata
            """
            result = await self.execute_command("getSelectedPhotos")
            
            return {
                "success": True,
                "count": result.get("count", 0),
                "photos": result.get("photos", []),
                "has_selection": result.get("count", 0) > 0
            }
        
        @self.server.tool
        async def catalog_select_photo(
            photo_id: Union[str, int]
        ) -> Dict[str, Any]:
            """
            Select a specific photo in Lightroom.
            
            Allows AI agents to change which photo they're editing.
            
            Args:
                photo_id: Photo ID to select
                
            Returns:
                Selection confirmation
            """
            await self.execute_command("setSelectedPhotos", {
                "photoIds": [str(photo_id)]
            })
            
            return {
                "success": True,
                "selected_photo_id": str(photo_id),
                "message": "Photo selected"
            }
        
        @self.server.tool
        async def catalog_get_all_photos(
            limit: int = 100,
            offset: int = 0
        ) -> Dict[str, Any]:
            """
            Get all photos in the catalog with pagination.
            
            For AI agents to browse available photos.
            
            Args:
                limit: Maximum photos to return (default 100)
                offset: Starting position for pagination
                
            Returns:
                List of photos with metadata
            """
            result = await self.execute_command("getAllPhotos", {
                "limit": limit,
                "offset": offset
            })
            
            return {
                "success": True,
                "total_count": result.get("totalCount", 0),
                "returned_count": len(result.get("photos", [])),
                "photos": result.get("photos", []),
                "limit": limit,
                "offset": offset,
                "has_more": result.get("totalCount", 0) > offset + limit
            }
        
        @self.server.tool
        async def catalog_search_photos(
            keyword: Optional[str] = None,
            rating_min: Optional[int] = None,
            rating_max: Optional[int] = None,
            file_format: Optional[str] = None,
            date_after: Optional[str] = None,
            date_before: Optional[str] = None,
            limit: int = 100
        ) -> Dict[str, Any]:
            """
            Search photos with flexible criteria.

            Powerful search for AI agents to find specific photos.

            Args:
                keyword: Search by keyword name
                rating_min: Minimum star rating (1-5)
                rating_max: Maximum star rating (1-5)
                file_format: Filter by format (RAW, JPEG, etc.)
                date_after: Photos after this date (YYYY-MM-DD)
                date_before: Photos before this date (YYYY-MM-DD)
                limit: Maximum results (default 100)

            Returns:
                Matching photos
            """
            criteria = {}
            if keyword:
                criteria["keyword"] = keyword
            if rating_min is not None or rating_max is not None:
                criteria["rating"] = {}
                if rating_min is not None:
                    criteria["rating"]["min"] = rating_min
                if rating_max is not None:
                    criteria["rating"]["max"] = rating_max
            if file_format:
                criteria["fileFormat"] = file_format
            if date_after:
                criteria["captureDate"] = criteria.get("captureDate", {})
                criteria["captureDate"]["after"] = date_after
            if date_before:
                criteria["captureDate"] = criteria.get("captureDate", {})
                criteria["captureDate"]["before"] = date_before

            result = await self.execute_command("searchPhotos", {
                "criteria": criteria,
                "limit": limit
            })

            return {
                "success": True,
                "count": len(result.get("photos", [])),
                "photos": result.get("photos", []),
                "criteria": criteria
            }
        
        @self.server.tool
        async def catalog_get_photo_metadata(
            photo_id: Union[str, int]
        ) -> Dict[str, Any]:
            """
            Get comprehensive metadata for a photo.
            
            Detailed information for AI analysis.
            
            Args:
                photo_id: Photo ID
                
            Returns:
                Complete photo metadata including EXIF data
            """
            result = await self.execute_command("getPhotoMetadata", {
                "photoId": str(photo_id)
            })
            
            return {
                "success": True,
                "photo_id": str(photo_id),
                "metadata": result
            }
        
        @self.server.tool
        async def catalog_get_collections() -> Dict[str, Any]:
            """
            Get all collections in the catalog.
            
            For AI agents to understand photo organization.
            
            Returns:
                List of collections with photo counts
            """
            result = await self.execute_command("getCollections")
            
            return {
                "success": True,
                "count": len(result.get("collections", [])),
                "collections": result.get("collections", [])
            }
        
        @self.server.tool
        async def catalog_get_keywords(
            limit: int = 500,
            offset: int = 0,
            include_counts: bool = False
        ) -> Dict[str, Any]:
            """
            Get keywords in the catalog with pagination.

            Helps AI agents understand photo categorization.
            Use include_counts=True for photo counts (slower).

            Args:
                limit: Max keywords to return (default 500)
                offset: Starting position for pagination
                include_counts: Include photo count per keyword (slow for large catalogs)

            Returns:
                Keywords with optional usage counts, pagination info
            """
            result = await self.execute_command("getKeywords", {
                "limit": limit,
                "offset": offset,
                "includeCounts": include_counts
            })

            return {
                "success": True,
                "count": result.get("count", 0),
                "total": result.get("total", 0),
                "offset": result.get("offset", 0),
                "has_more": result.get("hasMore", False),
                "keywords": result.get("keywords", [])
            }
        
        @self.server.tool
        async def catalog_get_keyword_tree(
            include_counts: bool = False,
            max_depth: int = 10
        ) -> Dict[str, Any]:
            """
            Get the full keyword hierarchy as a nested tree.

            Returns all keywords with parent-child nesting.
            Use include_counts=True for photo counts per keyword (slower).

            Args:
                include_counts: Include photo count per keyword (default False)
                max_depth: Maximum nesting depth (default 10)

            Returns:
                Nested keyword tree with id, name, children, and optional photoCount
            """
            result = await self.execute_command("getKeywordTree", {
                "includeCounts": include_counts,
                "maxDepth": max_depth
            })

            return {
                "success": True,
                "top_level_count": result.get("topLevelCount", 0),
                "total_count": result.get("totalCount", 0),
                "keywords": result.get("keywords", [])
            }

        @self.server.tool
        async def catalog_create_keyword(
            keyword_name: str,
            parent_id: Optional[int] = None,
            dry_run: bool = True
        ) -> Dict[str, Any]:
            """
            Create a keyword in the catalog hierarchy.

            Creates under a parent keyword if parent_id is provided,
            otherwise at top level. Returns existing keyword if name
            already exists at that level. Dry run by default.

            Args:
                keyword_name: Name for the new keyword
                parent_id: Parent keyword ID (from get_keyword_tree). None = top level
                dry_run: If True, report what would happen (default True)

            Returns:
                Created keyword with id, name, parent info
            """
            params = {"keywordName": keyword_name, "dryRun": dry_run}
            if parent_id is not None:
                params["parentId"] = parent_id
            result = await self.execute_command("createKeyword", params)
            return {"success": True, **result}

        @self.server.tool
        async def catalog_batch_stamp_by_path(
            items_json: str,
            dry_run: bool = True
        ) -> Dict[str, Any]:
            """
            Batch stamp keywords on photos found by file path.

            Takes a JSON array of items, each with 'path' and 'keywords'.
            Finds each photo by path and applies the keywords. Dry run by default.

            Args:
                items_json: JSON array of {path: string, keywords: string[]}
                    e.g. '[{"path":"C:/Photos/2004/photo.jpg","keywords":["Dads Collection","Trips"]}]'
                dry_run: If True, check which photos exist without stamping (default True)

            Returns:
                Count of stamped, not found, and errored photos
            """
            import json
            items = json.loads(items_json)
            result = await self.execute_command("batchStampByPath", {
                "items": items,
                "dryRun": dry_run
            })
            return {"success": True, **result}

        @self.server.tool
        async def catalog_batch_stamp_from_file(
            manifest_path: str,
            chunk_size: int = 100,
            skip: int = 0,
            dry_run: bool = True
        ) -> Dict[str, Any]:
            """
            Batch stamp keywords from a JSON manifest file.

            Reads a JSON array of {path, keywords} from a file and processes
            in chunks. Use skip to resume after partial completion.

            Args:
                manifest_path: Path to JSON manifest file
                chunk_size: Items per batch (default 100)
                skip: Number of items to skip from start (default 0)
                dry_run: If True, check without stamping (default True)

            Returns:
                Aggregate counts of stamped, not found, and errored photos
            """
            import json

            with open(manifest_path, "r") as f:
                all_items = json.load(f)

            items = all_items[skip:]
            total = len(items)
            chunks = [items[i:i + chunk_size] for i in range(0, total, chunk_size)]

            totals = {"stamped": 0, "notFound": 0, "errors": 0}
            chunk_results = []

            for i, chunk in enumerate(chunks):
                result = await self.execute_command("batchStampByPath", {
                    "items": chunk,
                    "dryRun": dry_run
                })
                totals["stamped"] += result.get("stamped", 0)
                totals["notFound"] += result.get("notFound", 0)
                totals["errors"] += result.get("errors", 0)
                chunk_results.append({
                    "chunk": i + 1,
                    "stamped": result.get("stamped", 0),
                    "notFound": result.get("notFound", 0),
                    "errors": result.get("errors", 0)
                })

            return {
                "success": True,
                "dry_run": dry_run,
                "total_items": total,
                "chunks_processed": len(chunks),
                "skipped": skip,
                **totals,
                "chunk_details": chunk_results
            }

        @self.server.tool
        async def catalog_create_smart_collection(
            name: str,
            search_desc_json: str,
            parent_id: Optional[int] = None
        ) -> Dict[str, Any]:
            """
            Create a smart collection with rule-based criteria.

            search_desc_json is the same searchDesc shape Lightroom uses for
            findPhotos. Pass through native LrC structure as JSON — do NOT
            invent a parallel DSL.

            Simple form (single criterion):
                '{"criteria": "rating", "operation": ">=", "value": 3}'

            Compound form (multiple criteria combined):
                '{"criteria": [
                    {"criteria": "keywords", "operation": "any", "value": "source:unclassified"},
                    {"criteria": "captureTime", "operation": "inLast", "value": 90, "value_units": "days"}
                ], "combine": "intersect"}'

            Common criteria fields: rating, pickFlag, keywords, captureTime,
            fileFormat, hasGPSData, label, folder, filename, dimensions.
            Common operations: ==, !=, >=, <=, any, all, none, contains,
            beginsWith, endsWith, inLast, isInRange.
            Combine: "intersect" (AND), "union" (OR), "exclude" (NOT).

            If a smart collection with this name already exists at the same
            level, returns the existing one instead of erroring.

            Args:
                name: Name for the smart collection
                search_desc_json: JSON-encoded searchDesc structure
                parent_id: Optional parent collection set ID (None = top level)

            Returns:
                Created smart collection with id, name, type
            """
            import json
            search_desc = json.loads(search_desc_json)
            params = {"name": name, "searchDesc": search_desc}
            if parent_id is not None:
                params["parentId"] = parent_id
            result = await self.execute_command("createSmartCollection", params)
            return {"success": True, **result}

        @self.server.tool
        async def catalog_get_smart_collection_criteria(
            collection_id: int
        ) -> Dict[str, Any]:
            """
            Get a smart collection's search criteria (searchDesc).

            Use catalog_get_collections first to discover collection IDs.

            Args:
                collection_id: localIdentifier of the smart collection

            Returns:
                {id, name, searchDesc} where searchDesc is the native LrC
                criteria structure (suitable for round-trip into update)
            """
            result = await self.execute_command("getSmartCollectionCriteria", {
                "collectionId": collection_id
            })
            return {"success": True, **result}

        @self.server.tool
        async def catalog_update_smart_collection(
            collection_id: int,
            search_desc_json: str
        ) -> Dict[str, Any]:
            """
            Replace a smart collection's search criteria.

            search_desc_json uses the same shape as catalog_create_smart_collection.
            This is a full replacement, not a merge — the new criteria overwrite
            the old completely.

            Args:
                collection_id: localIdentifier of the smart collection
                search_desc_json: JSON-encoded searchDesc structure

            Returns:
                {id, name} of the updated collection
            """
            import json
            search_desc = json.loads(search_desc_json)
            result = await self.execute_command("updateSmartCollection", {
                "collectionId": collection_id,
                "searchDesc": search_desc
            })
            return {"success": True, **result}

        @self.server.tool
        async def catalog_delete_smart_collection(
            collection_id: int
        ) -> Dict[str, Any]:
            """
            Delete a smart collection.

            Only works on smart collections. Use a different tool to delete
            regular collections (this guards against accidental loss of
            manually-curated collection contents).

            Args:
                collection_id: localIdentifier of the smart collection

            Returns:
                {id, name, deleted: true}
            """
            result = await self.execute_command("deleteSmartCollection", {
                "collectionId": collection_id
            })
            return {"success": True, **result}

        @self.server.tool
        async def catalog_get_folders() -> Dict[str, Any]:
            """
            Get all folders in the catalog.

            For AI agents to understand folder organization.
            
            Returns:
                Folder hierarchy with photo counts
            """
            result = await self.execute_command("getFolders")
            
            return {
                "success": True,
                "count": len(result.get("folders", [])),
                "folders": result.get("folders", [])
            }
        
        @self.server.tool
        async def catalog_set_rating(
            photo_id: Union[str, int],
            rating: int
        ) -> Dict[str, Any]:
            """
            Set rating for a photo.
            
            Allows AI agents to rate photos based on analysis.
            
            Args:
                photo_id: Photo ID
                rating: Rating (0-5 stars)
                
            Returns:
                Rating confirmation
            """
            if not 0 <= rating <= 5:
                raise ValueError(f"Rating must be 0-5, got {rating}")
            
            await self.execute_command("setPhotoRating", {
                "photoId": str(photo_id),
                "rating": rating
            })
            
            return {
                "success": True,
                "photo_id": str(photo_id),
                "rating": rating,
                "message": f"Photo rated {rating} stars"
            }
        
        @self.server.tool
        async def catalog_add_keywords(
            photo_id: Union[str, int],
            keywords: List[str]
        ) -> Dict[str, Any]:
            """
            Add keywords to a photo.
            
            Allows AI agents to tag photos based on content analysis.
            
            Args:
                photo_id: Photo ID
                keywords: List of keywords to add
                
            Returns:
                Keywords confirmation
            """
            await self.execute_command("addPhotoKeywords", {
                "photoId": str(photo_id),
                "keywords": keywords
            })
            
            return {
                "success": True,
                "photo_id": str(photo_id),
                "keywords_added": keywords,
                "count": len(keywords)
            }

        @self.server.tool
        async def catalog_get_keyword_photos(
            keyword_id: Optional[int] = None,
            keyword_name: Optional[str] = None,
            limit: int = 100,
            offset: int = 0
        ) -> Dict[str, Any]:
            """
            Find all photos that have a specific keyword assigned.
            Use keyword_id for fast lookup (get IDs from catalog_get_keywords).

            Args:
                keyword_id: Keyword ID (fast — direct lookup)
                keyword_name: Keyword name (slower — scans all keywords)
                limit: Max photos to return (default 100)
                offset: Starting position for pagination

            Returns:
                Photos with the keyword, pagination info
            """
            params = {"limit": limit, "offset": offset}
            if keyword_id is not None:
                params["keywordId"] = keyword_id
            elif keyword_name is not None:
                params["keywordName"] = keyword_name
            else:
                return {"success": False, "error": "keyword_id or keyword_name required"}

            result = await self.execute_command("getKeywordPhotos", params)

            return {
                "success": True,
                "keyword": keyword_name or f"id:{keyword_id}",
                "matched_keywords": result.get("matchedKeywords", 0),
                "count": result.get("count", 0),
                "total": result.get("total", 0),
                "has_more": result.get("hasMore", False),
                "photos": result.get("photos", [])
            }

        @self.server.tool
        async def catalog_set_photo_metadata(
            photo_id: Union[str, int],
            field: str,
            value: str
        ) -> Dict[str, Any]:
            """
            Set a metadata field on a photo (Artist, Caption, etc.).

            Args:
                photo_id: Photo ID
                field: Metadata field name (artist, caption, copyright, title,
                       headline, city, state, country, location, creator)
                value: Value to set

            Returns:
                Confirmation of the update
            """
            result = await self.execute_command("setPhotoMetadata", {
                "photoId": str(photo_id),
                "field": field,
                "value": value
            })

            return {
                "success": True,
                "photo_id": str(photo_id),
                "field": field,
                "value": value
            }

        @self.server.tool
        async def catalog_batch_set_metadata_by_keyword(
            field: str,
            value: str,
            keyword_id: Optional[int] = None,
            keyword_name: Optional[str] = None,
            dry_run: bool = True
        ) -> Dict[str, Any]:
            """
            Batch set a metadata field on all photos with a specific keyword.
            Skips photos that already have the correct value.
            Dry run by default — shows what would change without changing it.

            Args:
                field: Metadata field (artist, caption, copyright, title, etc.)
                value: Value to set
                keyword_id: Keyword ID (fast lookup)
                keyword_name: Keyword name (slower, scans catalog)
                dry_run: If True, report what would change without changing (default True)

            Returns:
                Count of stamped, skipped, and total photos
            """
            params = {"field": field, "value": value, "dryRun": dry_run}
            if keyword_id is not None:
                params["keywordId"] = keyword_id
            elif keyword_name is not None:
                params["keywordName"] = keyword_name
            else:
                return {"success": False, "error": "keyword_id or keyword_name required"}

            result = await self.execute_command("batchSetMetadataByKeyword", params)

            return {
                "success": True,
                "field": field,
                "value": value,
                "keyword": result.get("keywordName", ""),
                "stamped": result.get("stamped", 0),
                "would_stamp": result.get("wouldStamp", 0),
                "skipped": result.get("skipped", 0),
                "errors": result.get("errors", 0),
                "total": result.get("total", 0),
                "dry_run": dry_run
            }

        @self.server.tool
        async def catalog_delete_keyword(
            keyword_id: Optional[int] = None,
            keyword_name: Optional[str] = None,
            dry_run: bool = True
        ) -> Dict[str, Any]:
            """
            Delete a keyword from the catalog entirely.
            Removes it from all photos. Dry run by default.

            Args:
                keyword_id: Keyword ID (fast lookup)
                keyword_name: Keyword name (slower)
                dry_run: If True, report what would happen (default True)

            Returns:
                Deletion result with photo count affected
            """
            params = {"dryRun": dry_run}
            if keyword_id is not None:
                params["keywordId"] = keyword_id
            elif keyword_name is not None:
                params["keywordName"] = keyword_name
            else:
                return {"success": False, "error": "keyword_id or keyword_name required"}

            result = await self.execute_command("deleteKeyword", params)
            return {"success": True, **result}

        @self.server.tool
        async def catalog_batch_delete_keywords(
            keyword_ids_csv: str,
            dry_run: bool = True
        ) -> Dict[str, Any]:
            """
            Batch delete keywords from the catalog by ID.
            Dry run by default. Use for cleanup passes.

            Args:
                keyword_ids_csv: Comma-separated keyword IDs (e.g., "16735,16810,16839")
                dry_run: If True, report what would happen (default True)

            Returns:
                Count of deleted keywords
            """
            keyword_ids = [int(x.strip()) for x in keyword_ids_csv.split(",") if x.strip()]
            result = await self.execute_command("batchDeleteKeywords", {
                "keywordIds": keyword_ids,
                "dryRun": dry_run
            })
            return {"success": True, "dry_run": dry_run, "requested": len(keyword_ids), **result}

        @self.server.tool
        async def catalog_get_photo_info(
            photo_id: Union[str, int]
        ) -> Dict[str, Any]:
            """
            Get basic photo information.
            
            Quick access to essential photo details.
            
            Args:
                photo_id: Photo ID
                
            Returns:
                Basic photo information
            """
            result = await self.execute_command("getPhotoInfo", {
                "photoId": str(photo_id)
            })
            
            return {
                "success": True,
                "photo_id": str(photo_id),
                "info": result
            }

# Create server instance
catalog_server = CatalogServer()