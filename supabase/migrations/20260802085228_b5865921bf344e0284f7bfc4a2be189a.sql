alter table public.body_compositions
  add column if not exists raw_signals jsonb;

comment on column public.body_compositions.raw_signals is
  '秤端原始信号与链路诊断存档：resistance50/resistance500/has_resistance 等硬件直出值，以及命中的回调层级(source_layer)、字段名清单、连接参数个数、重连次数、会话错误码、设备型号、hmac。仅用于故障归因与日后复算，绝不包含任何派生指标值（体脂率/BMI 等一律只存在各自的指标列里），也不包含用户档案字段值。';