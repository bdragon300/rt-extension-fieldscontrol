use inc::Module::Install;

RTx 'RT-Extension-FieldsControl';
license 'perl';
author 'Igor Derkach <gosha753951@gmail.com>';
version '0.1';

requires_rt('4.0.0');
auto_install();

sign;
&WriteAll;