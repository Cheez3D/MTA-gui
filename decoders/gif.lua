--[[ ============================================================================================== ]

    NAME:    table decode_gif(string bytes)
    PURPOSE: Convert .gif files into drawable MTA:SA textures

    RETURNED TABLE STRUCTURE (EXAMPLE):

    {
        isAnimation = true,
        
        -- OPTIONAL: only if gif contains any comments and ignoreComments is false, otherwise nil
        [ comments = {
            [1] = "Hello world",
            [2] = "This is a gif file",
            ...
        }, ]
        
        -- OPTIONAL: only if isAnimation == true, otherwise nil
        [ loopCount = 2, ]
        
        width = 30, height = 60,
        
        -- FOR isAnimation = false
        image = userdata,
        
        -- FOR isAnimation = true
        [1] = {
            image = userdata,
            
            -- OPTIONAL: only if isAnimation == true, otherwise nil
            [ delay = 10, ] -- in milliseconds
        },
        
        [2] = {
            image = userdata,
            
            [ delay = 100, ]
        },
        
        ...
    }

    REFERENCES: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
                
                https://en.wikipedia.org/wiki/GIF
                
                http://commandlinefanatic.com/cgi-bin/showarticle.cgi?article=art011
                http://commandlinefanatic.com/cgi-bin/showarticle.cgi?article=art010
                
                http://giflib.sourceforge.net/whatsinagif/bits_and_bytes.html
                http://giflib.sourceforge.net/whatsinagif/lzw_image_data.html
                
                http://giflib.sourceforge.net/whatsinagif/animation_and_transparency.html
                http://www.vurdalakov.net/misc/gif/netscape-looping-application-extension
                
                http://www.onicos.com/staff/iz/formats/gif.html
                http://www.martinreddy.net/gfx/2d/GIF87a.txt
                http://www.fileformat.info/format/gif/egff.htm
                https://brianbondy.com/downloads/articles/gif.doc
                http://www.daubnet.com/en/file-format-gif
                
                https://stackoverflow.com/questions/26894809/gif-lzw-decompression
            
--[ ============================================================================================== ]]



local classes = classes;

local math = math;
local string = string;

local LOG2 = math.log(2);

local ALPHA255_BYTE     = string.char(0xff);
local TRANSPARENT_PIXEL = string.char(0x00, 0x00, 0x00, 0x00);



local EXTENSION_INTRODUCER = 0x21;

local APPLICATION_LABEL     = 0xff;
local COMMENT_LABEL         = 0xfe;
local GRAPHIC_CONTROL_LABEL = 0xf9;
local PLAIN_TEXT_LABEL      = 0x01;

local IMAGE_SEPARATOR = 0x2c;

local BLOCK_TERMINATOR = 0x00;

local TRAILER = 0x3b;


local NETSCAPE_LOOP_COUNT = 1;


local DISPOSE_TO_BACKGROUND = 2;
local DISPOSE_TO_PREVIOUS   = 3;



local decode_lzw_data;

function decode_gif(bytes, ignoreComments)
    
    local bytesType = type(bytes);
    if (bytesType ~= "string") then
        error("bad argument #1 to '" ..__func__.. "' (string expected, got " ..bytesType.. ")", 2);
    end
    
    if (ignoreComments ~= nil) then
        local ignoreCommentsType = type(ignoreComments);
        
        if (ignoreCommentsType ~= "boolean") then
            error("bad argument #2 to '" ..__func__.. "' (boolean expected, got " ..ignoreCommentsType.. ")");
        end
    else
        ignoreCommentsType = true;
    end
    
    
    local success, stream = pcall(classes.Stream.new, bytes);
    if (not success) then
        error("bad argument #1 to '" ..__func__.. "' (could not create stream)\n-> " ..stream, 2);
    end
    
    
    if (stream:read(3) ~= "GIF") then
        error("bad argument #1 to '" ..__func__.. "' (invalid file format)", 2);
    end
    
    local version = stream:read(3);
    
    if (version ~= "87a") and (version ~= "89a") then
        error("bad argument #1 to '" ..__func__.. "' (unsupported version)", 2);
    end
    
    
    
    local frames = {}
    
    -- [ ====================== [ LOGICAL SCREEN DESCRIPTOR ] ====================== ] 
    
    local lsd = {
        canvasWidth  = stream:read_ushort(),
        canvasHeight = stream:read_ushort(),
        
        fields = stream:read_uchar(),
        
        -- background color index, denotes which color to use for pixels with unspecified color index
        bgColorIndex = stream:read_uchar(),
        
        pixelAspectRatio = stream:read_uchar(),
    }
    
    do
        local fields = lsd.fields;
        
        lsd.fields = {
            gctFlag = bitExtract(fields, 7, 1), -- denotes wether a global color table exists
            gctSize = bitExtract(fields, 0, 3), -- number of entries in gct is 2^(gctSize+1)
            
            sortFlag = bitExtract(fields, 3, 1), -- denotes wether gct sorted (most important colors first)
            
            colorResolution = bitExtract(fields, 4, 3),
        }
    end
    
    frames.width  = lsd.canvasWidth;
    frames.height = lsd.canvasHeight;
    
    
    -- [ ====================== [ GLOBAL COLOR TABLE ] ====================== ]
    
    local gct;
    
    if (lsd.fields.gctFlag == 1) then
        gct = {}
        
        for i = 1, 2^(lsd.fields.gctSize+1) do
            gct[i] = stream:read(3):reverse() .. ALPHA255_BYTE;
        end
        
        
        local bgColor = gct[lsd.bgColorIndex+1];
        
        gct.bgColor = 0x1000000 * 0xff             -- a
                    + 0x10000   * bgColor:byte(1)  -- r
                    + 0x100     * bgColor:byte(2)  -- g
                    +             bgColor:byte(3); -- b
    end
    
    
    local isAnimation = false;
    
    local gce; -- current graphic control extension in use
    
    local canvas;
    local previousCanvas; -- used with the DISPOSE_TO_PREVIOUS disposal method
    
    
    local identifier = stream:read_uchar();
    
    while (identifier ~= TRAILER) do
    
        if (identifier == EXTENSION_INTRODUCER) then
            local label = stream:read_uchar();
            
            local blockSize   = stream:read_uchar();
            local blockOffset = stream.pos;
            
            if (label == GRAPHIC_CONTROL_LABEL) then
                if (blockSize ~= 4) then
                    error("bad argument #1 to '" ..__func__.. "' (invalid graphic control extension at " ..stream.pos.. ")", 2);
                end
                
                gce = {
                    size = blockSize,
                    
                    fields = stream:read_uchar(),
                    
                    delay = stream:read_ushort(),
                    
                    transparentColorIndex = stream:read_uchar(),
                }
                
                local fields = gce.fields;
                
                gce.fields = {
                    transparentColorFlag = bitExtract(fields, 0, 1),
                    userInputFlag = bitExtract(fields, 1, 1),
                    
                    disposalMethod = bitExtract(fields, 2, 3),
                    
                    reserved = bitExtract(fields, 5, 3),
                }
                
                gce.isTransparencyEnabled = (gce.fields.transparentColorFlag == 1);
                
                stream.pos = blockOffset+blockSize;
            elseif (label == APPLICATION_LABEL) then
                if (blockSize ~= 11) then
                    error("bad argument #1 to '" ..__func__.. "' (invalid application extension at " ..stream.pos.. ")", 2);
                end
                
                local appIdentifier = stream:read(8);
                local appAuthCode   = stream:read(3);
                
                blockSize   = stream:read_uchar();
                blockOffset = stream.pos;
                
                while (blockSize ~= BLOCK_TERMINATOR) do
                    if (appIdentifier == "NETSCAPE") and (appAuthCode == "2.0") then
                        local ID = stream:read_uchar();
                        
                        if (ID == NETSCAPE_LOOP_COUNT) then
                            isAnimation = true;
                            
                            frames.loopCount = stream:read_ushort();
                        end
                    end
                    
                    stream.pos = blockOffset+blockSize;
                    
                    blockSize   = stream:read_uchar();
                    blockOffset = stream.pos;
                end
            elseif (label == COMMENT_LABEL) and (not ignoreComments) then
                if (not frames.comments) then frames.comments = {} end
                
                local comment = {}
                
                while (blockSize ~= BLOCK_TERMINATOR) do
                    comment[#comment+1] = stream:read(blockSize);
                    
                    stream.pos = blockOffset+blockSize;
                    
                    blockSize   = stream:read_uchar();
                    blockOffset = stream.pos;
                end
                
                frames.comments[#frames.comments+1] = table.concat(comment);
            else
                -- skip unknown extension
                while (blockSize ~= BLOCK_TERMINATOR) do
                    stream.pos = blockOffset+blockSize;
                    
                    blockSize   = stream:read_uchar();
                    blockOffset = stream.pos;
                end
            end
            
        elseif (identifier == IMAGE_SEPARATOR) then
            -- [ IMAGE DESCRIPTOR ]
            
            local descriptor = {
                x = stream:read_ushort(),
                y = stream:read_ushort(),
                
                width  = stream:read_ushort(),
                height = stream:read_ushort(),
                
                fields = stream:read_uchar(),
            }
            
            local fields = descriptor.fields;
            
            descriptor.fields = {
                lctFlag = bitExtract(fields, 7, 1), -- local color table flag, denotes wether a local color table exists
                lctSize = bitExtract(fields, 0, 3), -- number of entries in table is 2^(lctSize + 1)
                
                interlaceFlag = bitExtract(fields, 6, 1),
                sortFlag = bitExtract(fields, 5, 1),
                
                reserved = bitExtract(fields, 3, 2),
            }
            
            descriptor.isInterlaced = (descriptor.fields.interlaceFlag == 1);
            
            
            -- [ ====================== [ LOCAL COLOR TABLE ] ====================== ]
            
            local lct;
            
            if (descriptor.fields.lctFlag == 1) then
                lct = {}
                
                for i = 1, 2^(descriptor.fields.lctSize+1) do
                    lct[i] = stream:read(3):reverse() .. ALPHA255_BYTE;
                end
            end
            
            
            -- [ ====================== [ IMAGE DATA ] ====================== ]
            
            -- if lct is not present fall back to gct
            local colorTable = lct or gct;
            
            if (gce) and (gce.isTransparencyEnabled) then
                gce.transparentColor = colorTable[gce.transparentColorIndex+1];
                
                -- temporarily replace transparent color with a transparent pixel
                -- to increase performance (vs comparing each index against gce.transparentColorIndex in the decoding process)
                colorTable[gce.transparentColorIndex+1] = TRANSPARENT_PIXEL;
            end
            
            
            local texture, textureWidth, textureHeight = decode_lzw_data(stream, gce, descriptor, colorTable);
            
            
            dxSetBlendMode("add");
            
            if (not canvas) then
                canvas = dxCreateRenderTarget(lsd.canvasWidth, lsd.canvasHeight, version == "89a"); -- only version 89a has transparency support
                
                local bgColor = ((gce and gce.isTransparencyEnabled) and 0x00000000) or (gct and gct.bgColor) or 0x00000000;
                
                dxDrawRectangle(descriptor.x, descriptor.y, descriptor.width, descriptor.height, bgColor);
            end
            
            -- if disposal method is DISPOSE_TO_PREVIOUS then save current canvas state
            -- so that it can be resored later
            
            local disposalMethod = gce and gce.fields.disposalMethod;
            
            if (disposalMethod == DISPOSE_TO_PREVIOUS) and (not previousCanvas) then
                previousCanvas = dxCreateRenderTarget(
                    lsd.canvasWidth, lsd.canvasHeight,
                    
                    true -- no need to check for version here as disposal method was introduced in version 89a
                );
                
                dxSetRenderTarget(previousCanvas);
                dxDrawImage(0, 0, lsd.canvasWidth, lsd.canvasHeight, canvas);
            elseif (disposalMethod ~= DISPOSE_TO_PREVIOUS) and (previousCanvas) then
                previousCanvas = nil;
            end
            
            
            -- draw decoded image on canvas
            
            dxSetRenderTarget(canvas);
            dxDrawImage(descriptor.x, descriptor.y, textureWidth, textureHeight, texture);
            
            
            -- copy canvas state to a new render target to be saved in the frames table
            
            local image = dxCreateRenderTarget(lsd.canvasWidth, lsd.canvasHeight, (version == "89a"));
            
            dxSetRenderTarget(image);
            dxDrawImage(0, 0, lsd.canvasWidth, lsd.canvasHeight, canvas);
            
            
            -- [ ====================== [ FRAME DISPOSAL ] ====================== ]
            
            -- REFERENCES: 
            -- http://www.webreference.com/content/studio/disposal.html
            -- http://www.theimage.com/animation/pages/disposal.html
            
            dxSetBlendMode("overwrite");
            
            if (disposalMethod == DISPOSE_TO_BACKGROUND) then
                
                dxSetRenderTarget(canvas);
                
                -- if current frame has transparency replace background color with transparent color
                -- to avoid displaying transparent images with solid backgrounds
                
                -- REFERENCE:
                -- https://github.com/DhyanB/Open-Imaging - see Quirks section
                
                local bgColor = ((gce and gce.isTransparencyEnabled) and 0x00000000) or (gct and gct.bgColor) or 0x00000000;
                
                -- only restore/overwrite area occupied by current frame
                
                -- REFERENCE:
                -- https://bugzilla.mozilla.org/show_bug.cgi?id=85595#c28
                
                dxDrawRectangle(descriptor.x, descriptor.y, descriptor.width, descriptor.height, bgColor);
                
            elseif (disposalMethod == DISPOSE_TO_PREVIOUS) then
                
                dxSetRenderTarget(canvas);
                dxDrawImage(0, 0, lsd.canvasWidth, lsd.canvasHeight, previousCanvas);
                
            end
            
            dxSetRenderTarget();
            
            dxSetBlendMode("blend");
            
            
            if (gce) and (gce.transparentColor) then
                -- restore transparent color after decoding of the image data and disposal
                colorTable[gce.transparentColorIndex+1] = gce.transparentColor;
                
                gce.transparentColor = nil;
            end
            
            
            -- insert newly obtained frame into frames table
            
            local frame = {}
            
            frame.image = image;
            
            frame.delay = gce and isAnimation and 10*gce.delay; -- multiply by 10 to get delay in milliseconds
            
            frames[#frames+1] = frame;
        end
        
        identifier = stream:read_uchar();
    end
    
    frames.isAnimation = isAnimation;
    
    return frames;
end



local MAX_CODE_SIZE = 12;

local DEINTERLACE_PASSES = {
    [1] = { y = 0, step = 8 },
    [2] = { y = 4, step = 8 },
    [3] = { y = 2, step = 4 },
    [4] = { y = 1, step = 2 },
}

function decode_lzw_data(stream, gce, descriptor, colorTable)
    
    -- the minimum LZW code size from which we compute
    -- the starting code size for reading the codes from the image data
    local lzwMinCodeSize = stream:read_uchar();
    
    
    -- round image width and height to the nearest powers of two
    -- to avoid bulrring when creating texture
    local textureWidth  = 2^math.ceil(math.log(descriptor.width)/LOG2);
    local textureHeight = 2^math.ceil(math.log(descriptor.height)/LOG2);
    
    
    local pixelData = {}
    
    -- x, y coordinates of current pixel
    local x = 0;
    local y = 0;
    
    
    local pass; -- pass of deinterlacing process
    local step; -- how many rows to skip
    
    if (descriptor.isInterlaced) then
        pass = 1;
        
        y    = DEINTERLACE_PASSES[pass].y;
        step = DEINTERLACE_PASSES[pass].step;
    end
    
    
    local dict = {} -- initialize the dictionary for storing the LZW codes
    
    -- insert all color indexes into dictionary
    
    -- +---------------------------------------------------------------------------------------+
    -- | ONLY UP TO 2^lzwMinCodeSize                                                           |
    -- +---------------------------------------------------------------------------------------+
    -- | previously used #colorTable and was causing unexpected results for cradle.gif because |
    -- | the colorTable size was 256 whereas the codeSize was 128 for some frames              |
    -- +---------------------------------------------------------------------------------------+
    
    -- using strings to represent indexes in color table
    -- this works because GIF max color table size conicides
    -- with number of ASCII characters, i.e. 256
    
    -- strings are used for efficiency vs tables
    
    for i = 1, 2^lzwMinCodeSize do dict[i] = string.char(i-1) end
    
    -- insert CLEAR_CODE and EOI_CODE into dictionary
    local CLEAR_CODE = 2^lzwMinCodeSize;  dict[#dict+1] = true;
    local EOI_CODE   = CLEAR_CODE+1;      dict[#dict+1] = true;
    
    -- index from which LZW compression codes start
    local lzwCodesOffset = #dict+1;
    
    
    local codeSize = lzwMinCodeSize+1;
    local dictMaxSize = 2^codeSize;
    
    local code = 0;
    local codeReadBits = 0;
    local isWholeCode = true;
    
    local previousCode;
    
    local isEOIReached = false;

    
    local blockSize   = stream:read_uchar();
    local blockOffset = stream.pos;
    
    local byte = stream:read_uchar();
    
    -- variable keeping track of starting point for reading from byte
    local bitOffset = 0;
    
    while (blockSize ~= BLOCK_TERMINATOR) do
        local codeUnreadBits = codeSize-codeReadBits;
        
        if ((bitOffset+codeUnreadBits) > 8) then
            isWholeCode = false;
            
            -- lower the amount of bits to read so as to reach exactly the byte end
            codeUnreadBits = 8-bitOffset;
        end
        
        code = (2^codeReadBits)*bitExtract(byte, bitOffset, codeUnreadBits) + code;
        codeReadBits = codeReadBits+codeUnreadBits;
        
        bitOffset = (bitOffset+codeUnreadBits)%8;
        
        if (isWholeCode) then
            if (code == CLEAR_CODE) then
                
                -- clear all dictionary entries created during the decoding process
                -- (i.e. all entries > EOI_CODE)
                for j = lzwCodesOffset, #dict do dict[j] = nil end
                
                -- it is necessary to reset previousCode
                -- because otherwise it might get picked up at [*] (see below)
                previousCode = nil;
                
                -- reset code size
                codeSize = lzwMinCodeSize+1;
                dictMaxSize = 2^codeSize;
                
            elseif (code == EOI_CODE) then
                isEOIReached = true;
                
                -- move to end of block to read BLOCK_TERMINATOR and exit out of the loop
                stream.pos = blockOffset+blockSize;
            else
                code = code+1; -- accomodate to Lua indexing which starts from 1
                
                -- [ ====================== [ CODE -> INDEXES CONVERSION ] ====================== ]
                
                -- +----------------------------------------------------+
                -- | LZW GIF DECOMPRESSION ALGORITHM                    |
                -- +----------------------------------------------------+
                -- | {CODE}   = indexes stored by CODE                  |
                -- | {CODE-1} = indexes stored by CODE-1 (prevous code) |
                -- +----------------------------------------------------+
                -- | <LOOP POINT>                                       |
                -- | let CODE be the next code in the code stream       |
                -- | is CODE in the code table?                         |
                -- | Yes:                                               |
                -- |     output {CODE} to index stream                  |
                -- |     let K be the first index in {CODE}             |
                -- |     add {CODE-1} .. K to the code table            |
                -- | No:                                                |
                -- |     let K be the first index of {CODE-1}           |
                -- |     output {CODE-1} .. K to index stream           |
                -- |     add {CODE-1} .. K to code table                |
                -- | return to <LOOP POINT>                             |
                -- +----------------------------------------------------+
                
                local indexes;
                
                if (dict[code]) then
                    local v = dict[code];
                    
                    indexes = v;
                    
                    local K = v:sub(1, 1);
                    if (previousCode and dict[previousCode]) then
                        dict[#dict+1] = dict[previousCode] .. K;
                    end
                else
                    local v = dict[previousCode];
                    
                    local K = v:sub(1, 1);
                    v = v .. K;
                    
                    indexes = v;
                    
                    dict[#dict+1] = v;
                end
                
                -- if inserting into dictionary increased codeSize
                if (#dict == dictMaxSize) and (codeSize < MAX_CODE_SIZE) then
                    codeSize = codeSize+1;
                    dictMaxSize = 2^codeSize;
                end
                
                previousCode = code;
                
                
                -- [ ====================== [ INDEXES -> PIXELS CONVERSION ] ====================== ]
                
                -- add colors coresponding to the decompressed color indexes to pixel data
                local pixelsCount = indexes:len();
                
                for i = 1, pixelsCount do
                    local index = indexes:byte(i);
                    local pixel = colorTable[index+1];
                    
                    -- add 1 to descriptor.width to allocate an index in the array for TRANSPARENT_PIXEL padding
                    -- (for power of two size)
                    pixelData[y*(descriptor.width+1) + (x+1)] = pixel;
                    
                    x = x+1;
                    
                    if (x >= descriptor.width) then
                        -- pad remaining row space horizontally with transparent pixels
                        pixelData[y*(descriptor.width+1) + (descriptor.width+1)] = TRANSPARENT_PIXEL:rep(textureWidth-descriptor.width);
                        
                        x = 0;
                        
                        if (descriptor.isInterlaced) then
                            y = y+step;
                            
                            if ((y >= descriptor.height) and (pass < #DEINTERLACE_PASSES)) then
                                pass = pass+1;
                                
                                y    = DEINTERLACE_PASSES[pass].y;
                                step = DEINTERLACE_PASSES[pass].step;
                            end
                        else
                            y = y+1;
                        end
                    end
                end
                
            end
            
            code = 0;
            codeReadBits = 0;
        else
            isWholeCode = true;
        end
        
        
        -- if reached end of block
        if ((stream.pos-blockOffset) == blockSize) then
            blockSize   = stream:read_uchar();
            blockOffset = stream.pos;
        end
        
        -- if we are at the beginning of a new byte <=> bitOffset == 0
        if (not isEOIReached) and (bitOffset == 0) then
            byte = stream:read_uchar();
        end
    end
    
    -- pad remaining bottom area with transparent pixels
    pixelData[#pixelData+1] = TRANSPARENT_PIXEL:rep((textureHeight-descriptor.height)*textureWidth);
    
    -- append size to accomodate MTA pixel data format
    pixelData[#pixelData+1] = string.char(
        bitExtract(textureWidth,  0, 8), bitExtract(textureWidth,  8, 8),
        bitExtract(textureHeight, 0, 8), bitExtract(textureHeight, 8, 8)
    );
    
    local pixels = table.concat(pixelData);
    
    return dxCreateTexture(pixels, "argb", false, "clamp"), textureWidth, textureHeight;
end






-- local h1, h2, h3 = debug.gethook();
-- debug.sethook();

-- local s = getTickCount();

-- local frames = decode_gif("decoders/gif/gta5.gif");
-- print_debug("loopCount =", frames.loopCount);

-- print_debug("elapsed =", getTickCount() - s, "ms");

-- debug.sethook(nil, h1, h2, h3);


-- local i = 1;
-- local t = getTickCount();

-- addEventHandler("onClientRender", root, function()
    -- if ((getTickCount() - t) >= (frames[i].delay or 1000)) then -- print(i, frames[i].delay, "ms");
        -- t = getTickCount();
        
        -- i = i+1;
        
        -- if (i > #frames) then i = 1 end
    -- end
    
    -- dxDrawImage(200, 200, frames.width, frames.height, frames[i].image);
-- end);
