import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { FieldGrid, Field } from "@/components/desktop/form/FieldGrid";

const TAG_COLORS = [
  { value: "blue", label: "蓝色" },
  { value: "green", label: "绿色" },
  { value: "red", label: "红色" },
  { value: "yellow", label: "黄色" },
  { value: "purple", label: "紫色" },
];

interface ClientTagCreateDialogProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  name?: string;
  onNameChange?: (value: string) => void;
  color?: string;
  onColorChange?: (value: string) => void;
  onSubmit?: () => void;
}

export default function ClientTagCreateDialog({
  open = false,
  onOpenChange,
  name = "",
  onNameChange,
  color = "blue",
  onColorChange,
  onSubmit,
}: ClientTagCreateDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[440px]">
        <DialogHeader>
          <DialogTitle className="pc-section-title">新建标签</DialogTitle>
          <p className="pc-caption">标签建好后可以用来筛选客户、批量打标</p>
        </DialogHeader>

        <FieldGrid cols={2}>
          <Field label="标签名称">
            <Input
              value={name}
              onChange={(event) => onNameChange?.(event.target.value)}
              placeholder="如：减重中"
              onKeyDown={(event) => {
                if (event.key === "Enter" && name.trim()) onSubmit?.();
              }}
            />
          </Field>
          <Field label="颜色">
            <Select value={color} onValueChange={onColorChange}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {TAG_COLORS.map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
        </FieldGrid>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange?.(false)}>
            取消
          </Button>
          <Button onClick={onSubmit} disabled={!name.trim()}>
            创建
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
