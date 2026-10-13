import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { FieldGrid, Field } from "@/components/desktop/form/FieldGrid";
import { maskPhone } from "@/lib/phone-mask";

export interface ClientFormValue {
  nickname: string;
  phone: string;
  notes: string;
}

interface ClientFormFieldsProps {
  value?: ClientFormValue;
  onChange?: (next: ClientFormValue) => void;
  phoneLocked?: boolean;
  onSubmit?: () => void;
  submitting?: boolean;
}

export default function ClientFormFields({
  value = { nickname: "", phone: "", notes: "" },
  onChange,
  phoneLocked = false,
  onSubmit,
  submitting = false,
}: ClientFormFieldsProps) {
  const patch = (partial: Partial<ClientFormValue>) => onChange?.({ ...value, ...partial });
  const canSubmit = Boolean(value.nickname.trim() || value.phone.trim());

  return (
    <FieldGrid cols={2}>
      <Field label={phoneLocked ? "客户姓名" : "客户昵称"} htmlFor="client-nickname">
        <Input
          id="client-nickname"
          value={value.nickname}
          onChange={(event) => patch({ nickname: event.target.value })}
          placeholder="怎么称呼这位客户"
          onKeyDown={(event) => {
            if (event.key === "Enter" && canSubmit && !submitting) onSubmit?.();
          }}
        />
      </Field>
      {phoneLocked ? (
        <Field label="手机号" htmlFor="client-phone-locked" hint="手机号不可修改">
          <Input id="client-phone-locked" value={maskPhone(value.phone)} disabled className="opacity-70" />
        </Field>
      ) : (
        <Field label="手机号" htmlFor="client-phone" hint="填了手机号，客户注册后能自动对上">
          <Input
            id="client-phone"
            value={value.phone}
            onChange={(event) => patch({ phone: event.target.value })}
            placeholder="11 位手机号"
            inputMode="numeric"
            maxLength={11}
          />
        </Field>
      )}
      <Field label="备注" htmlFor="client-notes" span="full">
        <Textarea
          id="client-notes"
          value={value.notes}
          onChange={(event) => patch({ notes: event.target.value })}
          placeholder="健康目标、注意事项、沟通偏好……"
          rows={3}
        />
      </Field>
    </FieldGrid>
  );
}
