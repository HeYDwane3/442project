require 'hdf5'
require('optim')
require('os')
require('cunn')
require('paths')
require('debug')

cmd = torch.CmdLine()
cmd:option('-m', 'hourglass3', 'model file definition')
cmd:option('-bs', 4, 'batch size')
cmd:option('-it', 0, 'Iterations')
cmd:option('-lt', 1000, 'Loss file saving refresh interval (seconds)')
cmd:option('-mt', 10000, 'Model saving interval (iterations)')
cmd:option('-et', 3000, 'Model evaluation interval (iterations)')
cmd:option('-lr', 1e-2, 'Learning rate')
cmd:option('-t_depth_file','','Training file for relative depth')
cmd:option('-rundir', '', 'Running directory')
cmd:option('-ep', 10, 'Epochs')
cmd:option('-start_from','', 'Start from previous model')
cmd:option('-diw',false,'Is training on DIW dataset')

g_args = cmd:parse(arg)

-- Data Loader
if g_args.diw then
    paths.dofile('./DataLoader_DIW.lua')
else
    paths.dofile('./DataLoader.lua')
end
paths.dofile('load_data.lua')
train_loader = TrainDataLoader()
mysum=0;

----------to modify
if g_args.it == 0 then
    g_args.it = g_args.ep * (20000) / g_args.bs
    print(g_args.it)
    debug.debug()
end

-- Run path
local jobid = os.getenv('PBS_JOBID')
local job_name = os.getenv('PBS_JOBNAME')
if g_args.rundir == '' then
    if jobid == '' then
        jobid = 'debug'
    else
        jobid = jobid:split('%.')[1]
    end
    g_args.rundir = '/home/wfchen/scratch/nips16_release/relative_depth/results/' .. g_args.m .. '/' .. job_name .. '/'
end
paths.mkdir(g_args.rundir)
torch.save(g_args.rundir .. '/g_args.t7', g_args)

-- Model
local config = {}
require('./models/' .. g_args.m)
if g_args.start_from ~= '' then
    require 'cudnn'
    print(g_args.rundir .. g_args.start_from)
    g_model = torch.load(g_args.rundir .. g_args.start_from);
    if g_model.period == nil then
        g_model.period = 1
    end
    g_model.period = g_model.period + 1
    config = g_model.config
else
    g_model = get_model()
    g_model.period = 1
end
g_model:training()
config.learningRate = g_args.lr



-- Criterion. get_criterion is a function, which is specified in the network model file
if get_criterion == nil then
    print("Error: no criterion specified!!!!!!!")
    os.exit()
end


-- Validation Criteria






-- Variables that used globally
g_criterion = get_criterion()
g_model = g_model:cuda()
g_criterion = g_criterion:cuda()
g_params, g_grad_params = g_model:getParameters()




local function default_feval(current_params)
    local batch_input, batch_target = train_loader:load_next_batch(g_args.bs)
    -- reset grad_params
    g_grad_params:zero()    
    --forward & backward
    local batch_output = g_model:forward(batch_input)    
    local batch_loss = g_criterion:forward(batch_output, batch_target)
    local dloss_dx = g_criterion:backward(batch_output, batch_target)
    g_model:backward(batch_input, dloss_dx)    

    collectgarbage()

    return batch_loss, g_grad_params
end


local function save_model(model, dir, current_iter, config)
    model:clearState()        
    model.config = config
    torch.save(dir .. '/model_period'.. model.period .. '_' .. current_iter  .. '.t7' , model)
end











-----------------------------------------------------------------------------------------------------

if feval == nil then
	feval = default_feval
end


local train_loss = {};


local lfile = torch.DiskFile(g_args.rundir .. '/training_loss_period' .. g_model.period .. '.txt', 'w')

function myrmsprop(opfunc, x, config, state)
   -- (0) get/update state
   local config = config or {}
   local state = state or config
   local lr = config.learningRate or 1e-2
   local alpha = config.alpha or 0.99
   local epsilon = config.epsilon or 1e-8
   local wd = config.weightDecay or 0
   local mfill = config.initialMean or 0

   -- (1) evaluate f(x) and df/dx
   local fx, dfdx = opfunc(x)

   -- (2) weight decay
   if wd ~= 0 then
      dfdx:add(wd, x)
   end

   -- (3) initialize mean square values and square gradient storage
   if not state.m then
      state.m = torch.Tensor():typeAs(x):resizeAs(dfdx):fill(mfill)
      state.tmp = torch.Tensor():typeAs(x):resizeAs(dfdx)
      print("new moment")
   end

   -- (4) calculate new (leaky) mean squared values
   state.m:mul(alpha)
   state.m:addcmul(1.0-alpha, dfdx, dfdx)

   -- (5) perform update
   state.tmp:sqrt(state.m):add(epsilon)
   x:addcdiv(-lr, dfdx, state.tmp)

   -- return x*, f(x) before optimization
   return x, {fx}
end


for iter = 1, g_args.it do
    local params, current_loss = myrmsprop(feval, g_params, config)
    print(current_loss[1])
    lfile:writeString(current_loss[1] .. '\n')
    
    train_loss[#train_loss + 1] = current_loss[1]

    if iter % g_args.mt == 0 then        
        print(string.format('Saving model at iteration %d...', iter))
        save_model(g_model, g_args.rundir, iter, config)        
    end
    if iter % g_args.lt == 0 then
        print(string.format('Flusing training loss file at iteration %d...', iter))
        lfile:synchronize()        
    end
end

-- evaluate(g_model, g_args.bs, valid_loader)
lfile:close()
train_loader:close()
save_model(g_model, g_args.rundir, g_args.it, config)
