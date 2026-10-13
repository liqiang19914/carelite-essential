import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import PanelCard from "@/components/desktop/shell/PanelCard";
import ClientFormFields, { type ClientFormValue } from "./ClientFormFields";

interface ClientEditSheetProps {
  value?: ClientFormValue;
  onChange?: (next: ClientFormValue) => void;
  submitting?: boolean;
  onSubmit?: () => void;
  onCancel?: () => void;
}

export default function ClientEditSheet({
  value,
  onChange,
  submitting = false,
  onSubmit,
  onCancel,
}: ClientEditSheetProps) {
  const canSubmit = Boolean((value?.nickname ?? "").trim() || (value?.phone ?? "").trim());

  return (
    <PanelCard
      title="编辑客户"
      description="姓名是你对客户的备注称呼，手机号不可修改"
      className="h-full min-h-0"
      bodyClassName="min-h-0 space-y-4 overflow-y-auto"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onCancel} disabled={submitting}>
            取消
          </Button>
          <Button onClick={onSubmit} disabled={submitting || !canSubmit}>
            {submitting ? <Loader2 className="mr-1 h-3.5 w-3.5 animate-spin" /> : null}
            保存修改
          </Button>
        </div>
      }
    >
      <ClientFormFields
        value={value}
        onChange={onChange}
        phoneLocked
        onSubmit={onSubmit}
        submitting={submitting}
      />
    </PanelCard>
  );
}
