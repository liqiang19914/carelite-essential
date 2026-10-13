import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

interface UnsavedLeaveDialogProps {
  open?: boolean;
  title?: string;
  description?: string;
  stayLabel?: string;
  leaveLabel?: string;
  onStay?: () => void;
  onLeave?: () => void;
}

export default function UnsavedLeaveDialog({
  open = false,
  title = "有修改还没保存",
  description = "现在离开，刚填的内容会丢掉。要先保存吗？",
  stayLabel = "继续编辑",
  leaveLabel = "不保存，离开",
  onStay,
  onLeave,
}: UnsavedLeaveDialogProps) {
  return (
    <AlertDialog open={open} onOpenChange={(next) => !next && onStay?.()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>{description}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel onClick={onStay}>{stayLabel}</AlertDialogCancel>
          <AlertDialogAction onClick={onLeave}>{leaveLabel}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
