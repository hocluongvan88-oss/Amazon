import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { TenantProvider } from "@/lib/tenant";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin", "vietnamese"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: { default: "Vexim Ops – Amazon Managed Operations", template: "%s · Vexim Ops" },
  description: "Bảng điều khiển vận hành Amazon của Vexim: lợi nhuận, tồn kho, gợi ý và phê duyệt",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="vi" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="min-h-full">
        <TenantProvider>{children}</TenantProvider>
      </body>
    </html>
  );
}
