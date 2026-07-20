import type {
  ButtonHTMLAttributes,
  ReactElement,
  ReactNode,
} from "react";
import * as TooltipPrimitive from "@radix-ui/react-tooltip";
import type { LucideIcon } from "lucide-react";

type TooltipSide = "top" | "right" | "bottom" | "left";

export function UiProvider({ children }: { children: ReactNode }) {
  return (
    <TooltipPrimitive.Provider delayDuration={450} skipDelayDuration={120}>
      {children}
    </TooltipPrimitive.Provider>
  );
}

export function Tooltip({
  children,
  disabled = false,
  label,
  side = "bottom",
}: {
  children: ReactElement;
  disabled?: boolean;
  label: string;
  side?: TooltipSide;
}) {
  if (disabled) {
    return children;
  }
  return (
    <TooltipPrimitive.Root>
      <TooltipPrimitive.Trigger asChild>{children}</TooltipPrimitive.Trigger>
      <TooltipPrimitive.Portal>
        <TooltipPrimitive.Content
          className="ui-tooltip"
          collisionPadding={8}
          side={side}
          sideOffset={6}
        >
          {label}
        </TooltipPrimitive.Content>
      </TooltipPrimitive.Portal>
    </TooltipPrimitive.Root>
  );
}

type ButtonTone = "default" | "primary" | "danger";
type ButtonSize = "regular" | "compact";

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  icon?: LucideIcon;
  size?: ButtonSize;
  tone?: ButtonTone;
};

export function Button({
  children,
  className,
  icon: Icon,
  size = "regular",
  tone = "default",
  type = "button",
  ...props
}: ButtonProps) {
  return (
    <button
      className={classNames(
        "ui-button",
        tone !== "default" && tone,
        size !== "regular" && size,
        className,
      )}
      type={type}
      {...props}
    >
      {Icon ? <Icon aria-hidden="true" size={14} /> : null}
      {children}
    </button>
  );
}

type IconButtonProps = Omit<
  ButtonHTMLAttributes<HTMLButtonElement>,
  "aria-label" | "children" | "title"
> & {
  active?: boolean;
  icon: LucideIcon;
  label: string;
  tone?: ButtonTone;
  tooltipSide?: TooltipSide;
};

export function IconButton({
  active = false,
  className,
  icon: Icon,
  label,
  tone = "default",
  tooltipSide,
  type = "button",
  ...props
}: IconButtonProps) {
  return (
    <Tooltip label={label} side={tooltipSide}>
      <button
        aria-label={label}
        className={classNames(
          "icon-button",
          active && "active",
          tone !== "default" && tone,
          className,
        )}
        type={type}
        {...props}
      >
        <Icon aria-hidden="true" size={14} />
      </button>
    </Tooltip>
  );
}

function classNames(...values: Array<string | false | null | undefined>) {
  return values.filter(Boolean).join(" ");
}
