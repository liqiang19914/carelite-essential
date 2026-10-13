import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import ClientFormFields, { type ClientFormValue } from "./ClientFormFields";

export type { ClientFormValue } from "./ClientFormFields";

interface ClientFormDialogProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  title?: string;
  description?: string;
  submitLabel?: string;
  submitting?: boolean;
  value?: ClientFormValue;
  onChange?: (next: ClientFormValue) => void;
  onSubmit?: () => void;
  phoneLocked?: boolean;
}

export default function ClientFormDialog({
  open = false,
  onOpenChange,
  title = "新增客户",
  description,
  submitLabel = "保存",
  submitting = false,
  value = { nickname: "", phone: "", notes: "" },
  onChange,
  onSubmit,
  phoneLocked = false,
}: ClientFormDialogProps) {
  const canSubmit = Boolean(value.nickname.trim() || value.phone.trim());

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[560px]">
        <DialogHeader>
          <DialogTitle className="pc-section-title">{title}</DialogTitle>
          {description && <p className="pc-caption">{description}</p>}
          <DialogDescription className="sr-only">
            {title}
            {description ? `：${description}` : ""}
          </DialogDescription>
        </DialogHeader>

        <ClientFormFields
          value={value}
          onChange={onChange}
          phoneLocked={phoneLocked}
          onSubmit={onSubmit}
          submitting={submitting}
        />

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange?.(false)}>
            取消
          </Button>
          <Button onClick={onSubmit} disabled={submitting || !canSubmit}>
            {submitting ? <Loader2 className="mr-1 h-3.5 w-3.5 animate-spin" /> : null}
            {submitLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
