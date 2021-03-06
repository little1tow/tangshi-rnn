
-- Modified from https://github.com/oxford-cs-ml-2015/practical6
-- the modification included support for train/val/test splits

local PaddedLineSplitLoader = {}
PaddedLineSplitLoader.__index = PaddedLineSplitLoader
local vocab_size = 2000
-- local vocab_size = 3
-- * unknown
-- ^ begin
-- $ stop

function PaddedLineSplitLoader.create(data_dir, batch_size, seq_length, split_fractions)
    -- split_fractions is e.g. {0.9, 0.05, 0.05}

    local self = {}
    setmetatable(self, PaddedLineSplitLoader)

    local input_file = path.join(data_dir, 'input.txt')
    local vocab_file = path.join(data_dir, 'vocab.t7')
    local tensor_file = path.join(data_dir, 'data.t7')

    -- fetch file attributes to determine if we need to rerun preprocessing
    local run_prepro = false
    if not (path.exists(vocab_file) or path.exists(tensor_file)) then
        -- prepro files do not exist, generate them
        print('vocab.t7 and data.t7 do not exist. Running preprocessing...')
        run_prepro = true
    else
        -- check if the input file was modified since last time we 
        -- ran the prepro. if so, we have to rerun the preprocessing
        local input_attr = lfs.attributes(input_file)
        local vocab_attr = lfs.attributes(vocab_file)
        local tensor_attr = lfs.attributes(tensor_file)
        if input_attr.modification > vocab_attr.modification or input_attr.modification > tensor_attr.modification then
            print('vocab.t7 or data.t7 detected as stale. Re-running preprocessing...')
            run_prepro = true
        end
    end
    if run_prepro then
        -- construct a tensor with all the data, and vocab file
        print('one-time setup: preprocessing input text file ' .. input_file .. '...')
        PaddedLineSplitLoader.text_to_tensor(input_file, vocab_file, tensor_file)
    end

    print('loading data files...')
    local data = torch.load(tensor_file)
    self.vocab_mapping = torch.load(vocab_file)

    -- count vocab
    self.vocab_size = 0
    for _ in pairs(self.vocab_mapping) do 
        self.vocab_size = self.vocab_size + 1 
    end

    -- self.batches is a table of tensors
    print('reshaping tensor...')
    self.batch_size = batch_size
    local len = data:size(1)
    if ( len % batch_size ) ~= 0 then
        local newlength = math.floor(len / batch_size) * batch_size
        print("cutting off the end of data to make batch split evenly, total length " .. newlength)
        data = data:sub(1, newlength)
    end

    local ydata = data:sub(1,-1,2,-1):clone()
    -- ydata:sub(1,-2):copy(data:sub(2,-1))
    -- ydata[-1] = data[1]
    data = data:sub(1,-1, 1,-2)
    assert(ydata:size(2) == data:size(2))
    self.x_batches = data:split(batch_size, 1)  -- #rows = #batches
    self.nbatches = #self.x_batches
    self.y_batches = ydata:split(batch_size, 1)  -- #rows = #batches
    assert(#self.x_batches == #self.y_batches)

    -- lets try to be helpful here
    if self.nbatches < 50 then
        print('WARNING: less than 50 batches in the data in total? Looks like very small dataset. You probably want to use smaller batch_size and/or seq_length.')
    end

    -- perform safety checks on split_fractions
    assert(split_fractions[1] >= 0 and split_fractions[1] <= 1, 'bad split fraction ' .. split_fractions[1] .. ' for train, not between 0 and 1')
    assert(split_fractions[2] >= 0 and split_fractions[2] <= 1, 'bad split fraction ' .. split_fractions[2] .. ' for val, not between 0 and 1')
    assert(split_fractions[3] >= 0 and split_fractions[3] <= 1, 'bad split fraction ' .. split_fractions[3] .. ' for test, not between 0 and 1')
    if split_fractions[3] == 0 then 
        -- catch a common special case where the user might not want a test set
        self.ntrain = math.floor(self.nbatches * split_fractions[1])
        self.nval = self.nbatches - self.ntrain
        self.ntest = 0
    else
        -- divide data to train/val and allocate rest to test
        self.ntrain = math.floor(self.nbatches * split_fractions[1])
        self.nval = math.floor(self.nbatches * split_fractions[2])
        self.ntest = self.nbatches - self.nval - self.ntrain -- the rest goes to test (to ensure this adds up exactly)
    end

    self.split_sizes = {self.ntrain, self.nval, self.ntest}
    self.batch_ix = {0,0,0}

    print(string.format('data load done. Number of data batches in train: %d, val: %d, test: %d', self.ntrain, self.nval, self.ntest))
    collectgarbage()
    return self
end

function PaddedLineSplitLoader:reset_batch_pointer(split_index, batch_index)
    batch_index = batch_index or 0
    self.batch_ix[split_index] = batch_index
end

function PaddedLineSplitLoader:next_batch(split_index)
    if self.split_sizes[split_index] == 0 then
        -- perform a check here to make sure the user isn't screwing something up
        local split_names = {'train', 'val', 'test'}
        print('ERROR. Code requested a batch for split ' .. split_names[split_index] .. ', but this split has no data.')
        os.exit() -- crash violently
    end
    -- split_index is integer: 1 = train, 2 = val, 3 = test
    self.batch_ix[split_index] = self.batch_ix[split_index] + 1
    if self.batch_ix[split_index] > self.split_sizes[split_index] then
        self.batch_ix[split_index] = 1 -- cycle around to beginning
    end
    -- pull out the correct next batch
    local ix = self.batch_ix[split_index]
    if split_index == 2 then ix = ix + self.ntrain end -- offset by train set size
    if split_index == 3 then ix = ix + self.ntrain + self.nval end -- offset by train + val
    return self.x_batches[ix], self.y_batches[ix]
end

-- *** STATIC method ***
function PaddedLineSplitLoader.text_to_tensor(in_textfile, out_vocabfile, out_tensorfile)
    local timer = torch.Timer()

    print('loading text file...')
    local f = torch.DiskFile(in_textfile)
    local rawdata = f:readString('*a') -- NOTE: this reads the whole file at once
    f:close()

    -- create vocabulary if it doesn't exist yet
    print('creating vocabulary mapping...')
    -- record all characters to a set
    local unordered = {}
    local len = 0
    local linecount = 0
    local maxCharCount = 0
    local currentCharCount = 0
    -- code snippets taken from http://lua-users.org/wiki/LuaUnicode
    for char in string.gfind(rawdata, "([%z\1-\127\194-\244][\128-\191]*)") do
        if char == "\n" then
            linecount = linecount + 1
            if currentCharCount > maxCharCount then
                -- excluding the newline character
                maxCharCount = currentCharCount-1
            end
            currentCharCount = 0
        else
            if not unordered[char] then
                unordered[char] = 1
            else
                unordered[char] = unordered[char]+1
            end
            currentCharCount = currentCharCount + 1
        end
        len = len + 1
    end
    -- sort into a table (i.e. keys become 1..N)
    local ordered = {}
    --for char in pairs(unordered) do ordered[#ordered + 1] = char end
    for char, count in spairs(unordered, function(t,a,b) return t[b] < t[a] end) do
        ordered[#ordered + 1] = char
    end
    -- XXX what is this?
    -- table.sort(ordered)
    -- invert `ordered` to create the char->int mapping
    local vocab_mapping = {}
    local vocab_mapping_withu = {}
    local real_vocab_size = 1
    local vocab_occurance = 0
    for i, char in ipairs(ordered) do
        if i <= vocab_size then
            vocab_mapping_withu[char] = i
            vocab_mapping[char] = i
            vocab_occurance = vocab_occurance + unordered[char]
            real_vocab_size = real_vocab_size + 1
        else
            vocab_mapping_withu[char] = real_vocab_size 
        end
    end
    if real_vocab_size > vocab_size then
        print("Shrinked vocab size to " .. vocab_size .. ' from ' .. #ordered .. ' by replacing low occurance with *')
        print("vocab coverage character percentage" .. (vocab_size/#ordered) .. ' occurrance count ' .. vocab_occurance .. ' / ' .. len .. '(' .. (vocab_occurance/len) .. ')')
    end
    vocab_mapping['*'] = real_vocab_size
    vocab_mapping['^'] = real_vocab_size+1
    vocab_mapping['$'] = real_vocab_size+2
    -- construct a tensor with all the data
    print('putting data into tensor with dimension' .. linecount ..' line ' .. maxCharCount .. 'characters')
    -- NOTE: hack, my current data is one letter short on padding, so adding the s padding
    -- local data = torch.ShortTensor(len) -- store it into 1D first, then rearrange
    local data = torch.ShortTensor(linecount, maxCharCount+2)
    local pos = 1
    local linecount = 0
    local currentCharCount = 1
    -- code snippets taken from http://lua-users.org/wiki/LuaUnicode
    for char in string.gfind(rawdata, "([%z\1-\127\194-\244][\128-\191]*)") do
        if char == "\n" then
            -- more hack
            for p = currentCharCount, maxCharCount+2 do
                data[linecount+1][p] = vocab_mapping['$']
            end
            linecount = linecount + 1
            currentCharCount = 1
        else
            if currentCharCount == 1 then
                data[linecount+1][1] = vocab_mapping['^']
            end
            -- print(currentCharCount+1 .. ' ' .. pos .. ' ' .. len)
            data[linecount+1][currentCharCount+1] = vocab_mapping_withu[char]
            currentCharCount = currentCharCount + 1
        end
        pos = pos + 1
    end

    -- save output preprocessed files
    print('saving ' .. out_vocabfile)
    torch.save(out_vocabfile, vocab_mapping)
    print('saving ' .. out_tensorfile)
    torch.save(out_tensorfile, data)
end

function spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys 
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

return PaddedLineSplitLoader

